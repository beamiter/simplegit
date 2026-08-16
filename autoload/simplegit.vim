vim9script


# =============================================================
# Simplegit — Git superpowers for Vim 9 (blame, history, diff)
# Rendering stays in Vim9script; every git invocation runs in an
# asynchronous Rust daemon so editing never waits on git.
# =============================================================

# ----------- Daemon state -----------
var s_enabled: bool = false
var s_next_id: number = 0
var s_last_error: string = ''
var s_daemon_version: string = ''
var s_daemon_protocol: number = 0
var s_daemon_ready: bool = false
var s_daemon_incompatible: bool = false
# Consecutive daemon starts without a completed handshake; a broken binary
# must not be respawned on every request.

# Correlate asynchronous replies: id -> {kind, ...context}
var s_pending: dict<dict<any>> = {}
# Requests issued before the version handshake completed.
var s_wait_queue: list<dict<any>> = []
# Latest initial status request for each origin window/buffer/repository.
var s_status_request_generation: number = 0
var s_status_latest: dict<number> = {}
# Latest request for each asynchronously opened view (show/history/log/diff).
var s_view_generation: number = 0
var s_view_latest: dict<number> = {}

# ----------- Blame state -----------
# bufnr (string) -> {lines: list<string>, commits: dict<any>, failed: bool}
var s_blame_cache: dict<dict<any>> = {}
var s_blame_inflight: dict<bool> = {}
# Single-line blame, the annotation's fast path: bufnr (string) ->
# {tick: number, lines: dict<string>} where lines maps a line number to its
# rendered annotation.  An entry with an empty string means "asked, nothing to
# show", which is what stops the cursor from re-asking on every rest.
var s_line_blame_cache: dict<dict<any>> = {}
var s_line_blame_inflight: dict<bool> = {}
var s_blame_timer: number = 0
var s_line_blame_on: bool = true

# ----------- Hunk state -----------
# bufnr (string) -> {failed: bool, hunks: list<dict<any>>}
var s_hunk_cache: dict<dict<any>> = {}
var s_hunk_inflight: dict<bool> = {}
# Buffers that changed again while a hunks request was in flight.
var s_hunk_stale: dict<bool> = {}
# A jump or preview asked for while a refresh was in flight, to run when the
# answer lands: bufnr (string) -> purpose.
var s_hunk_pending_action: dict<string> = {}
var s_hunk_timer: number = 0
var s_status_refresh_timer: number = 0
var s_status_refresh_forced: bool = false
var s_status_refresh_repo_filter: string = ''
var s_status_refresh_excluded_repos: dict<bool> = {}
var s_signs_on: bool = true
var s_signs_defined: bool = false
var s_commit_generation: number = 0

const UNCOMMITTED = '0000000000000000000000000000000000000000'
const PROP_TYPE = 'simplegit_line_blame'
const SIGN_GROUP = 'simplegit'
const STATUS_BUF = 'simplegit://status'
const COMMIT_BUF = 'simplegit://commit'
const CAP_REPOSITORY_FILE_OPS = 'repository_file_ops'
const CAP_BRANCH_SUMMARY = 'branch_summary'
const CAP_BLAME_LINE = 'blame_line'
const CAP_HUNK_RANGE = 'hunk_range'
const CAP_REPO_WATCH = 'repo_watch'
const CAP_REMOTE_EXEC = 'remote_exec'
# How SimpleRemote names a file that lives in a remote workspace, and how this
# plugin spells every path it hands around for one: `remote:///abs/path`.  A
# path in that form is routed to the git of the workspace's host (see
# Dispatch()); a bare path is a local file, exactly as before.
const REMOTE_PREFIX = 'remote://'

# =============================================================
# Small helpers
# =============================================================
def ConfBool(name: string, default_val: bool): bool
  var value = get(g:, name, default_val)
  if type(value) == v:t_bool
    return value
  endif
  if type(value) == v:t_number
    return value != 0
  endif
  return default_val
enddef

def ConfNum(name: string, default_val: number): number
  var value = get(g:, name, default_val)
  return type(value) == v:t_number && value > 0 ? value : default_val
enddef

def DebugLog(message: string)
  s_last_error = message
  if ConfBool('simplegit_debug', false)
    echomsg '[SimpleGit] ' .. message
  endif
enddef

def Warn(message: string)
  echohl WarningMsg
  echomsg '[SimpleGit] ' .. message
  echohl None
enddef

def IsWin(): bool
  return has('win32') || has('win64')
enddef

# =============================================================
# Remote workspaces (SimpleRemote)
#
# A SimpleRemote workspace is an SSH host or a Docker container.  Its files
# reach Vim either as `remote:///abs/path` buffers (virtual mode: buftype
# acwrite, filled asynchronously, marked with b:vimrc_remote) or, when the
# workspace is projected through sshfs / a bind mount / an explicit mapping,
# as ordinary local files marked with b:simpleremote_path.  Local git cannot
# see a virtual buffer's file at all and sees a projected one only through the
# mount, so such buffers send their requests to the git *on the workspace
# host*: the daemon runs `<g:SimpleRemoteExecArgv()> git -C <dir> ...`.
#
# Nothing here requires SimpleRemote to be installed: every touch point is
# feature-detected, and without it every buffer is local.
# =============================================================
def IsRemotePath(path: string): bool
  return strpart(path, 0, len(REMOTE_PREFIX)) ==# REMOTE_PREFIX
enddef

# `/abs/path` for `remote:///abs/path`; a local path unchanged.
def RemotePlainPath(path: string): string
  return IsRemotePath(path) ? strpart(path, len(REMOTE_PREFIX)) : path
enddef

# The directory of a path, for both spellings.  fnamemodify(':h') is not
# enough on its own: it turns 'remote:///top.txt' into 'remote:', so the
# remote form is taken apart, modified as a plain path and put back together.
def PathDir(path: string): string
  if IsRemotePath(path)
    return REMOTE_PREFIX .. fnamemodify(RemotePlainPath(path), ':h')
  endif
  return fnamemodify(path, ':h')
enddef

def JoinPath(dir: string, name: string): string
  return dir =~# '/$' ? dir .. name : dir .. '/' .. name
enddef

# g:simplegit_remote_git: which buffers use the workspace's git.
#   'auto'    remote:// buffers -- they have no local file (default)
#   'always'  those, plus projected buffers marked with b:simpleremote_path,
#             so the git of the host runs instead of local git over the mount
#   'never'   none; remote:// buffers then have no git at all, as before
def RemoteMode(): string
  var mode = get(g:, 'simplegit_remote_git', 'auto')
  return type(mode) == v:t_string && index(['auto', 'always', 'never'], mode) >= 0
    ? mode : 'auto'
enddef

# The absolute path, on the workspace host, of the file a buffer's git work
# is about -- or '' for a buffer whose git runs locally.
def BufRemotePath(bufnr: number): string
  var mode = RemoteMode()
  if mode ==# 'never'
    return ''
  endif
  var info = getbufvar(bufnr, 'vimrc_remote', {})
  if type(info) == v:t_dict
    var path = get(info, 'path', '')
    if type(path) == v:t_string && path =~# '^/'
      return path
    endif
  endif
  if mode ==# 'always' && getbufvar(bufnr, '&buftype') ==# ''
    # A projected file of the workspace that is connected *now*; the marker
    # outlives a disconnect, and then local git over the mount is all there
    # is again.
    var projected = getbufvar(bufnr, 'simpleremote_path', '')
    var workspace = get(g:, 'simpleremote_workspace', {})
    if type(projected) == v:t_string && projected =~# '^/'
          && type(workspace) == v:t_dict
          && get(workspace, 'id', -1) == getbufvar(bufnr, 'simpleremote_workspace_id', -2)
      return projected
    endif
  endif
  return ''
enddef

def BufIsRemote(bufnr: number): bool
  return bufexists(bufnr) && BufRemotePath(bufnr) !=# ''
enddef

# Whether a workspace decided anything about this buffer -- a remote:// buffer
# or a projected file SimpleRemote marked -- regardless of whether one is
# connected *now*.  BufIsRemote() answers "route its git remotely today";
# this answers "what was remembered for it depends on a workspace", which is
# what has to be forgotten when one comes, goes or is replaced.
def BufWorkspaceTied(bufnr: number): bool
  if !bufexists(bufnr)
    return false
  endif
  var info = getbufvar(bufnr, 'vimrc_remote', {})
  if type(info) == v:t_dict && !empty(info)
    return true
  endif
  var projected = getbufvar(bufnr, 'simpleremote_path', '')
  if type(projected) == v:t_string && projected !=# ''
    return true
  endif
  return IsRemotePath(bufname(bufnr))
enddef

# A buffer git has something to say about: an ordinary file buffer, or a
# remote one -- whose buftype is acwrite and which every buftype gate used to
# skip.
def IsFileBuffer(bufnr: number): bool
  # getbufvar() answers '' for a buffer that does not exist, which reads as
  # "an ordinary file buffer"; ask first.
  return bufexists(bufnr)
    && (getbufvar(bufnr, '&buftype') ==# '' || BufIsRemote(bufnr))
enddef

# The path a buffer's requests name: a readable local file, or the
# `remote:///abs/path` of a remote one.  '' for anything else, which is what
# switches every feature off for that buffer.
def BufFilePath(bufnr: number): string
  if !bufexists(bufnr)
    return ''
  endif
  var remote = BufRemotePath(bufnr)
  if remote !=# ''
    return REMOTE_PREFIX .. remote
  endif
  if getbufvar(bufnr, '&buftype') !=# ''
    return ''
  endif
  # getbufinfo names are absolute, unlike bufname(), which would resolve
  # relative to whatever the current directory happens to be by now.
  var name = get(get(getbufinfo(bufnr), 0, {}), 'name', '')
  return name !=# '' && filereadable(name) ? name : ''
enddef

# Reasons remote git was refused, so each is said once rather than on every
# cursor rest.  Cleared when the workspace changes.
var s_remote_warned: dict<bool> = {}

# Why a remote request cannot go out right now, or '' when it can.  Decided
# per request rather than once: the daemon's capabilities arrive with its
# handshake, and SimpleRemote's transport comes and goes with the connection.
def RemoteUnavailable(): string
  if !exists('*g:SimpleRemoteExecArgv')
    return 'remote git needs SimpleRemote (g:SimpleRemoteExecArgv)'
  endif
  var workspace = get(g:, 'simpleremote_workspace', {})
  if type(workspace) != v:t_dict || empty(workspace)
    # Deliberately first among the real obstacles, and the one reason that is
    # never announced: between a disconnect and the next connection every
    # remote buffer still asks, and none of that is news to whoever
    # disconnected.
    return 'no SimpleRemote workspace is connected'
  endif
  # A probe that has finished always reports a `git` key -- empty when the
  # host has none.  While it is still in flight the dictionary holds only
  # {status: -1}, and without a runtime it is empty; neither says anything
  # about git, so neither refuses the request.
  var probe = get(workspace, 'probe', {})
  if type(probe) == v:t_dict && has_key(probe, 'git') && get(probe, 'git', '') ==# ''
    return 'git is not installed on the remote host'
  endif
  # Last: the transport is what a user can act on, and an old daemon is a
  # reason worth naming only once the rest is in place.
  if !simplegit#core#HasCap(CAP_REMOTE_EXEC)
    return 'remote git needs a newer daemon; rerun ./install.sh'
  endif
  return ''
enddef

def RemoteExecArgv(): list<string>
  var argv = call('g:SimpleRemoteExecArgv', [])
  return type(argv) == v:t_list ? argv : []
enddef

# Refuse a remote request the way the daemon would: the error reaches
# OnRequestError() *after* the caller has recorded the request as in flight,
# so the same bookkeeping that handles a daemon error -- the failure caches
# that stop a cursor rest from re-asking, the released view reservation, the
# reset commit buffer -- handles this one too.  Said once per reason; an
# interactive command still hears it every time it asks.
def RefuseRemote(ctx: dict<any>, reason: string)
  var deliver: dict<any> = copy(ctx)
  if !has_key(s_remote_warned, reason)
    s_remote_warned[reason] = true
    # A disconnect explains itself; the rest is worth one line.
    if reason !~# 'no SimpleRemote workspace'
      Warn(reason)
    endif
    deliver.interactive = false
  endif
  # Always from a timer, never inline: the caller marks its request as in
  # flight only after Dispatch() returns, so an error delivered before that
  # would leave the mark behind and the buffer would never ask again.  The
  # supervisor arms a timer for every request it sends anyway
  # (simplegit#core#Request), so this needs nothing a request did not.
  timer_start(0, (_) => OnRequestError(deliver, reason))
enddef

# Requests whose `path` is a repository directory rather than a file in one.
const DIR_REQUEST_TYPES = ['status', 'branch', 'watch', 'file_op', 'commit',
  'commit_message']

# Attach the workspace transport to a request whose path is remote: the exec
# prefix, the directory git runs in (the daemon must not guess it from the
# local filesystem) and the plain paths the git on the other side expects.
# False when it cannot be sent, in which case the refusal has been delivered.
def AttachRemote(wire: dict<any>, ctx: dict<any>): bool
  var reason = RemoteUnavailable()
  var argv: list<string> = reason ==# '' ? RemoteExecArgv() : []
  if reason ==# '' && empty(argv)
    reason = 'SimpleRemote has no argv-safe transport for this workspace'
  endif
  if reason !=# ''
    RefuseRemote(ctx, reason)
    return false
  endif
  var dir: string = get(ctx, 'dir', '')
  if type(dir) != v:t_string || dir ==# ''
    # The daemon must be told where git runs; it cannot stat a path on the
    # other machine to find out.  A repository-wide request names that
    # directory as its path, everything else names a file inside it -- and
    # only the request type can tell the two apart here.
    dir = index(DIR_REQUEST_TYPES, get(wire, 'type', '')) >= 0
      ? wire.path : PathDir(wire.path)
  endif
  wire.exec = argv
  wire.cwd = RemotePlainPath(dir)
  wire.path = RemotePlainPath(wire.path)
  if type(get(wire, 'file', v:null)) == v:t_string && IsRemotePath(wire.file)
    wire.file = RemotePlainPath(wire.file)
  endif
  return true
enddef

def ShortSha(sha: string): string
  return strpart(sha, 0, 7)
enddef

def TimeAgo(epoch: number): string
  var diff = localtime() - epoch
  if diff < 0
    diff = 0
  endif
  if diff < 60
    return 'just now'
  elseif diff < 3600
    var n = diff / 60
    return n .. (n == 1 ? ' minute ago' : ' minutes ago')
  elseif diff < 86400
    var n = diff / 3600
    return n .. (n == 1 ? ' hour ago' : ' hours ago')
  elseif diff < 604800
    var n = diff / 86400
    return n .. (n == 1 ? ' day ago' : ' days ago')
  elseif diff < 2592000
    var n = diff / 604800
    return n .. (n == 1 ? ' week ago' : ' weeks ago')
  elseif diff < 31536000
    var n = diff / 2592000
    return n .. (n == 1 ? ' month ago' : ' months ago')
  endif
  var n = diff / 31536000
  return n .. (n == 1 ? ' year ago' : ' years ago')
enddef

def CommitDate(epoch: number): string
  return epoch > 0 ? strftime('%Y-%m-%d', epoch) : '          '
enddef

# `↑2 ↓1` for a branch that has diverged from its upstream; empty when it has
# not diverged, or has no upstream at all.  Both counts arrive straight from
# the daemon, so tolerate a non-numeric value rather than throwing.
def UpstreamSuffix(ahead: any, behind: any): string
  var suffix = ''
  if type(ahead) == v:t_number && ahead > 0
    suffix ..= ' ↑' .. ahead
  endif
  if type(behind) == v:t_number && behind > 0
    suffix ..= ' ↓' .. behind
  endif
  return suffix
enddef

# =============================================================
# Daemon lifecycle (JSON lines over stdin/stdout)
# =============================================================
def FindDaemon(): string
  SetupCore()
  return simplegit#core#FindExe()
enddef

# The supervisor owns the process: liveness via job_status, generation-guarded
# callbacks, exponential-backoff restarts and a crash-loop breaker.  This file
# keeps only the protocol handshake and the request bookkeeping.
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simplegit#core#Setup({
    name: 'SimpleGit',
    exe: 'simplegit-daemon',
    path_var: 'simplegit_daemon_path',
    debug_var: 'simplegit_debug',
    handshake: {request: {type: 'version'}, reply_type: 'version', proto_key: 'protocol'},
    OnEvent: OnDaemonEvent,
    OnExit: OnDaemonExit,
  })
enddef

def SendRaw(req: dict<any>): bool
  return simplegit#core#Send(req)
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def ClearPending()
  var commit_bufnr = bufnr(COMMIT_BUF)
  if commit_bufnr > 0 && bufexists(commit_bufnr)
        && getbufvar(commit_bufnr, 'simplegit_commit_pending', false)
    setbufvar(commit_bufnr, 'simplegit_commit_pending', false)
    setbufvar(commit_bufnr, '&modified', 1)
  endif
  s_pending = {}
  s_wait_queue = []
  s_status_latest = {}
  s_view_latest = {}
  s_blame_inflight = {}
  s_line_blame_inflight = {}
  s_hunk_inflight = {}
  s_hunk_pending_action = {}
  s_branch_inflight = {}
  # A restarted daemon watches nothing, so every repository has to register
  # again; without this the plugin would believe it was still being told about
  # changes it can no longer hear.
  s_watch_requested = {}
  s_watch_roots = {}
enddef

def OnDaemonExit(code: number, restarting: bool)
  s_daemon_ready = false
  s_daemon_protocol = 0
  s_daemon_version = ''
  ClearPending()
enddef

def StartDaemon(): bool
  SetupCore()
  if simplegit#core#IsRunning()
    return true
  endif
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_version = ''
  s_daemon_protocol = 0
  return simplegit#core#Ensure()
enddef

# Send a request; queue it while the handshake is still in flight.
def Dispatch(req: dict<any>, ctx: dict<any>): bool
  if !simplegit#core#IsRunning() && !StartDaemon()
    return false
  endif
  if s_daemon_incompatible
    return false
  endif
  if !s_daemon_ready
    if len(s_wait_queue) < 32
      s_wait_queue->add({req: req, ctx: ctx})
    endif
    return true
  endif
  # Capabilities are known only after the handshake.  Keeping this gate here
  # (rather than in :SimpleGitStageAll) also covers requests that were queued
  # while a freshly started daemon was still negotiating protocol 5.
  var required = get(ctx, 'requires_capability', '')
  if type(required) == v:t_string && required !=# ''
        && !simplegit#core#HasCap(required)
    var message = required ==# CAP_REPOSITORY_FILE_OPS
      ? 'whole-repository stage/unstage requires a newer daemon; rerun ./install.sh'
      : 'daemon capability unavailable: ' .. required
    s_last_error = message
    if get(ctx, 'interactive', false)
      Warn(message)
    else
      DebugLog(message)
    endif
    # The request was deliberately handled without putting an unsupported
    # operation on the wire.  Returning true avoids a second, misleading
    # "daemon unavailable" warning at the call site.
    return true
  endif
  # Copy into a dict<any>: call sites pass all-string literals whose inferred
  # type would reject the numeric id.
  var wire: dict<any> = extend({}, req)
  if IsRemotePath(get(wire, 'path', '')) && !AttachRemote(wire, ctx)
    # Refused and reported through the error path; nothing went on the wire.
    return true
  endif
  var id = NextId()
  wire.id = id
  s_pending[string(id)] = ctx
  if !SendRaw(wire)
    remove(s_pending, string(id))
    return false
  endif
  return true
enddef

def FlushWaitQueue()
  var queued = s_wait_queue
  s_wait_queue = []
  for item in queued
    Dispatch(item.req, item.ctx)
  endfor
enddef

def TakePending(id: number): dict<any>
  var key = string(id)
  if id <= 0 || !has_key(s_pending, key)
    return {}
  endif
  return remove(s_pending, key)
enddef

def OnDaemonEvent(ev: dict<any>)
  if type(get(ev, 'type', v:null)) != v:t_string
    DebugLog('malformed daemon response')
    return
  endif
  if ev.type ==# 'version'
    OnVersion(ev)
    return
  endif
  if ev.type ==# 'repo_change'
    # Unsolicited: the daemon noticed something move in a watched repository.
    # It answers no request, so it has no correlatable id and has to be handled
    # before the pending lookup below rejects it as stale.
    OnRepoChange(ev)
    return
  endif
  var id = get(ev, 'id', 0)
  if type(id) != v:t_number
    DebugLog('daemon response without a numeric id')
    return
  endif
  var ctx = TakePending(id)
  if empty(ctx)
    DebugLog('ignored stale daemon response ' .. id)
    return
  endif
  if ev.type ==# 'error'
    OnRequestError(ctx, get(ev, 'message', 'unknown error'))
    return
  endif
  if ev.type !=# get(ctx, 'kind', '')
    DebugLog('daemon response type mismatch for request ' .. id)
    return
  endif
  if ev.type ==# 'blame'
    OnBlame(ctx, ev)
  elseif ev.type ==# 'blame_line'
    OnBlameLine(ctx, ev)
  elseif ev.type ==# 'log'
    OnLog(ctx, ev)
  elseif ev.type ==# 'graph_log'
    OnGraphLog(ctx, ev)
  elseif ev.type ==# 'show'
    OnShow(ctx, ev)
  elseif ev.type ==# 'cat'
    OnCat(ctx, ev)
  elseif ev.type ==# 'status'
    OnStatus(ctx, ev)
  elseif ev.type ==# 'branch'
    OnBranch(ctx, ev)
  elseif ev.type ==# 'watch'
    OnWatch(ctx, ev)
  elseif ev.type ==# 'hunks'
    OnHunks(ctx, ev)
  elseif ev.type ==# 'hunk_op'
    OnHunkOp(ctx, ev)
  elseif ev.type ==# 'file_op'
    OnFileOp(ctx, ev)
  elseif ev.type ==# 'commit'
    OnCommit(ctx, ev)
  elseif ev.type ==# 'commit_message'
    OnCommitMessage(ctx, ev)
  endif
enddef

def OnVersion(ev: dict<any>)
  # The id is assigned by the supervisor, which has already correlated this
  # reply to its handshake request; only the payload still needs validating.
  var version = get(ev, 'version', '')
  var protocol = get(ev, 'protocol', 0)
  if type(version) == v:t_string && version !=# '' && type(protocol) == v:t_number
    s_daemon_version = version
    s_daemon_protocol = protocol
    if protocol != 5
      s_daemon_ready = false
      s_daemon_incompatible = true
      ClearPending()
      DebugLog('unsupported daemon protocol ' .. protocol .. '; rerun ./install.sh')
    else
      s_daemon_ready = true
      s_daemon_incompatible = false
      s_last_error = ''
      FlushWaitQueue()
    endif
  else
    s_daemon_ready = false
    s_daemon_incompatible = true
    ClearPending()
    DebugLog('malformed daemon version response; rerun ./install.sh')
  endif
enddef

def OnRequestError(ctx: dict<any>, message: any)
  var text = type(message) == v:t_string ? message : string(message)
  # A failed request must release its view reservation, or the next request
  # for the same view would look superseded and be discarded in turn.
  var view_target = get(ctx, 'view_target', '')
  if view_target !=# ''
        && get(s_view_latest, view_target, -2) == get(ctx, 'view_generation', -1)
    remove(s_view_latest, view_target)
  endif
  if get(ctx, 'kind', '') ==# 'blame' || get(ctx, 'kind', '') ==# 'blame_line'
    var key = string(get(ctx, 'bufnr', -1))
    if has_key(s_blame_inflight, key)
      remove(s_blame_inflight, key)
    endif
    if has_key(s_line_blame_inflight, key .. ':' .. get(ctx, 'lnum', 0))
      remove(s_line_blame_inflight, key .. ':' .. get(ctx, 'lnum', 0))
    endif
    # Remember the failure so cursor movement does not hammer the daemon
    # with requests for files outside any repository.
    s_blame_cache[key] = {failed: true, lines: [], commits: {}}
  elseif get(ctx, 'kind', '') ==# 'hunks'
    var key = string(get(ctx, 'bufnr', -1))
    if has_key(s_hunk_inflight, key)
      remove(s_hunk_inflight, key)
    endif
    if has_key(s_hunk_pending_action, key)
      # The jump this buffer was waiting for cannot happen; say so rather than
      # leaving the keypress unexplained.
      remove(s_hunk_pending_action, key)
      Warn('no hunk information for this buffer')
    endif
    s_hunk_cache[key] = {failed: true, hunks: []}
  elseif get(ctx, 'kind', '') ==# 'branch'
    # Same rule as a successful reply: a failure that answers a superseded
    # question must not be cached, or a re-read that has already been issued
    # would be shadowed by it.
    if BranchReplyCurrent(ctx)
      RecordBranchFailure(get(ctx, 'repo_token', ''))
    endif
  elseif get(ctx, 'kind', '') ==# 'status'
    var request_key = get(ctx, 'status_request_key', '')
    if request_key !=# ''
          && get(s_status_latest, request_key, -1)
            == get(ctx, 'status_request_generation', -2)
      remove(s_status_latest, request_key)
    endif
  elseif get(ctx, 'kind', '') ==# 'commit'
    var commit_bufnr = get(ctx, 'commit_bufnr', -1)
    if commit_bufnr > 0 && bufexists(commit_bufnr)
          && getbufvar(commit_bufnr, 'simplegit_commit_generation', 0)
            == get(ctx, 'commit_generation', -1)
      setbufvar(commit_bufnr, 'simplegit_commit_pending', false)
      setbufvar(commit_bufnr, '&modified', 1)
    endif
  endif
  if get(ctx, 'interactive', false)
    Warn(text)
  else
    DebugLog('daemon error: ' .. strtrans(text))
  endif
enddef

# =============================================================
# Blame data
# =============================================================
def ValidBlame(ev: dict<any>): bool
  return type(get(ev, 'lines', v:null)) == v:t_list
        \ && type(get(ev, 'commits', v:null)) == v:t_dict
enddef

def RequestBlame(bufnr: number, purpose: string, interactive: bool): bool
  var path = BufFilePath(bufnr)
  if path ==# ''
    return false
  endif
  var key = string(bufnr)
  if has_key(s_blame_inflight, key)
    return true
  endif
  var ok = Dispatch({type: 'blame', path: path},
    {kind: 'blame', bufnr: bufnr, purpose: purpose, interactive: interactive})
  if ok
    s_blame_inflight[key] = true
  endif
  return ok
enddef

def OnBlame(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var key = string(bufnr)
  if has_key(s_blame_inflight, key)
    remove(s_blame_inflight, key)
  endif
  if !ValidBlame(ev)
    DebugLog('ignored malformed blame response')
    return
  endif
  if !bufexists(bufnr)
    return
  endif
  if len(s_blame_cache) >= 64 && !has_key(s_blame_cache, key)
    remove(s_blame_cache, keys(s_blame_cache)[0])
  endif
  s_blame_cache[key] = {failed: false, lines: ev.lines, commits: ev.commits}
  var purpose = get(ctx, 'purpose', 'virtual')
  if purpose ==# 'virtual'
    ShowLineBlameNow()
  elseif purpose ==# 'window'
    OpenBlameWindow(bufnr)
  elseif purpose ==# 'popup'
    ShowBlamePopup(bufnr)
  endif
enddef

def BlameFor(bufnr: number): dict<any>
  return get(s_blame_cache, string(bufnr), {})
enddef

def InvalidateBlame(bufnr: number)
  var key = string(bufnr)
  if has_key(s_blame_cache, key)
    remove(s_blame_cache, key)
  endif
  if has_key(s_line_blame_cache, key)
    remove(s_line_blame_cache, key)
  endif
enddef

const BLAME_FORMAT_DEFAULT = '%a, %w • %s'

# Render one commit through g:simplegit_blame_format.  Expanding every key in
# a single substitute() pass is what keeps a summary containing a literal `%`
# from being re-expanded as a format key of its own.
def FormatBlame(sha: string, info: dict<any>): string
  if sha ==# UNCOMMITTED
    return 'Uncommitted changes'
  endif
  var epoch = get(info, 'time', 0)
  var fields = {
    a: get(info, 'author', ''),
    e: get(info, 'email', ''),
    h: ShortSha(sha),
    d: CommitDate(epoch),
    w: TimeAgo(epoch),
    s: get(info, 'summary', ''),
    '%': '%',
  }
  var fmt = get(g:, 'simplegit_blame_format', BLAME_FORMAT_DEFAULT)
  if type(fmt) != v:t_string || fmt ==# ''
    fmt = BLAME_FORMAT_DEFAULT
  endif
  # An unknown key is left as typed, so a typo is visible rather than silently
  # swallowing the character after it.
  return substitute(fmt, '%\(.\)',
    (m: list<string>): string => get(fields, m[1], m[0]), 'g')
enddef

def LineAnnotation(blame: dict<any>, lnum: number): string
  var lines = get(blame, 'lines', [])
  if lnum < 1 || lnum > len(lines)
    return ''
  endif
  var sha = lines[lnum - 1]
  if sha ==# UNCOMMITTED
    return 'Uncommitted changes'
  endif
  var info = get(blame.commits, sha, {})
  if empty(info)
    return ''
  endif
  return FormatBlame(sha, info)
enddef

# =============================================================
# Single-line blame — the annotation's fast path
#
# Annotating one line used to blame the entire file: on a large file with deep
# history that is seconds of git plus a sha and a header block per line to
# decode on Vim's main thread, redone after every :w.  `git blame -L n,n` stops
# as soon as that one line is attributed.
# =============================================================
def LineBlameSupported(): bool
  # Capabilities are known only after the handshake; until then use the
  # whole-file request rather than one an older daemon cannot parse.
  return s_daemon_ready && simplegit#core#HasCap(CAP_BLAME_LINE)
enddef

# {} when this line has not been asked about yet; otherwise the commit fields,
# with an empty sha meaning "asked, nothing to show" — which is what stops the
# cursor from re-asking on every rest.  Raw fields rather than rendered text,
# so changing g:simplegit_blame_format takes effect without a refetch.
def CachedLineBlame(bufnr: number, lnum: number): dict<any>
  var entry = get(s_line_blame_cache, string(bufnr), {})
  if empty(entry) || get(entry, 'tick', -1) != getbufvar(bufnr, 'changedtick', -2)
    return {}
  endif
  var lines: dict<any> = get(entry, 'lines', {})
  return get(lines, string(lnum), {})
enddef

def RecordLineBlame(bufnr: number, lnum: number, info: dict<any>)
  var key = string(bufnr)
  var tick = getbufvar(bufnr, 'changedtick', 0)
  var entry: dict<any> = get(s_line_blame_cache, key, {})
  if empty(entry) || get(entry, 'tick', -1) != tick
    entry = {tick: tick, lines: {}}
  endif
  # Reading a long file line by line must not grow this without bound.
  if len(entry.lines) >= 1024
    entry.lines = {}
  endif
  entry.lines[string(lnum)] = info
  if len(s_line_blame_cache) >= 64 && !has_key(s_line_blame_cache, key)
    remove(s_line_blame_cache, keys(s_line_blame_cache)[0])
  endif
  s_line_blame_cache[key] = entry
enddef

def RequestLineBlame(bufnr: number, lnum: number, purpose: string, interactive: bool): bool
  var path = BufFilePath(bufnr)
  if path ==# ''
    return false
  endif
  var key = string(bufnr) .. ':' .. lnum
  if has_key(s_line_blame_inflight, key)
    return true
  endif
  var ok = Dispatch({type: 'blame_line', path: path, lnum: lnum},
    {kind: 'blame_line', bufnr: bufnr, lnum: lnum, purpose: purpose,
     interactive: interactive, changedtick: getbufvar(bufnr, 'changedtick', 0)})
  if ok
    s_line_blame_inflight[key] = true
  endif
  return ok
enddef

def OnBlameLine(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var lnum = get(ctx, 'lnum', 0)
  var key = string(bufnr) .. ':' .. lnum
  if has_key(s_line_blame_inflight, key)
    remove(s_line_blame_inflight, key)
  endif
  var sha = get(ev, 'sha', '')
  if type(sha) != v:t_string
    DebugLog('ignored malformed blame_line response')
    return
  endif
  if !bufexists(bufnr)
    return
  endif
  # An edit while the reply was in flight moved the line the answer describes.
  if getbufvar(bufnr, 'changedtick', 0) != get(ctx, 'changedtick', -1)
    return
  endif
  # Keep only the fields the annotation renders, not the whole event.
  var info = {
    sha: sha,
    author: get(ev, 'author', ''),
    email: get(ev, 'email', ''),
    time: get(ev, 'time', 0),
    summary: get(ev, 'summary', ''),
  }
  RecordLineBlame(bufnr, lnum, info)
  if get(ctx, 'purpose', 'virtual') ==# 'popup'
    ShowLineBlamePopup(bufnr, lnum, sha, info)
  elseif bufnr == bufnr('%') && lnum == line('.')
    ShowLineBlameNow()
  endif
enddef

# =============================================================
# Inline (current line) blame — GitLens style virtual text
# =============================================================
def VirtualTextSupported(): bool
  return has('textprop') && has('patch-9.0.0067')
enddef

def EnsurePropType()
  if empty(prop_type_get(PROP_TYPE))
    prop_type_add(PROP_TYPE, {highlight: 'SimpleGitBlameVirtual'})
  endif
enddef

def ClearLineBlame(bufnr: number)
  if !VirtualTextSupported() || !bufexists(bufnr)
    return
  endif
  if !empty(prop_type_get(PROP_TYPE))
    prop_remove({type: PROP_TYPE, bufnr: bufnr, all: true})
  endif
enddef

def ShowLineBlameNow()
  if !s_enabled || !s_line_blame_on || !VirtualTextSupported()
    return
  endif
  if mode() !=# 'n'
    return
  endif
  var bufnr = bufnr('%')
  ClearLineBlame(bufnr)
  if getbufvar(bufnr, '&modified') || BufFilePath(bufnr) ==# ''
    return
  endif
  var lnum = line('.')
  var blame = BlameFor(bufnr)
  if get(blame, 'failed', false)
    return
  endif
  var text = ''
  if !empty(blame)
    # The sidebar already paid for the whole file; reuse it rather than
    # asking again per line.
    text = LineAnnotation(blame, lnum)
  elseif LineBlameSupported()
    var cached = CachedLineBlame(bufnr, lnum)
    if empty(cached)
      RequestLineBlame(bufnr, lnum, 'virtual', false)
      return
    endif
    var sha: string = get(cached, 'sha', '')
    text = sha ==# '' ? '' : FormatBlame(sha, cached)
  else
    RequestBlame(bufnr, 'virtual', false)
    return
  endif
  if text ==# ''
    return
  endif
  EnsurePropType()
  prop_add(lnum, 0, {
    type: PROP_TYPE,
    bufnr: bufnr,
    text: '    ' .. text,
    text_align: 'after',
    text_wrap: 'truncate',
  })
enddef

export def ScheduleLineBlame()
  if !s_enabled || !s_line_blame_on || !VirtualTextSupported()
    return
  endif
  ClearLineBlame(bufnr('%'))
  if !has('timers')
    ShowLineBlameNow()
    return
  endif
  if s_blame_timer != 0
    timer_stop(s_blame_timer)
  endif
  # A remote buffer's annotation is one SSH round trip per cursor rest, so it
  # waits longer before asking: a cursor merely passing through a line then
  # costs nothing.  Latency itself is not consulted -- the probe measures a
  # shell script once at connect time -- one honest knob is easier to reason
  # about than a threshold that moves.
  var delay = BufIsRemote(bufnr('%'))
    ? ConfNum('simplegit_remote_blame_delay', 750)
    : ConfNum('simplegit_blame_delay', 350)
  s_blame_timer = timer_start(delay, (_) => {
    s_blame_timer = 0
    ShowLineBlameNow()
  })
enddef

export def OnBufWrite()
  var bufnr = bufnr('%')
  InvalidateBlame(bufnr)
  ScheduleLineBlame()
  InvalidateHunks(bufnr)
  RefreshHunks()
enddef

export def OnBufClose(bufnr: number)
  InvalidateBlame(bufnr)
  InvalidateHunks(bufnr)
enddef

# Refresh every visible file buffer after Git changes, not only the current
# one. Mutation callbacks share this without inheriting FocusGained's status
# auto-refresh policy.
#
# With a repository token, only buffers belonging to that repository are
# refreshed: that is what a pushed repo_change reports, and a change in one
# checkout says nothing about the file open next to it.
def RefreshVisibleGitState(repo_filter: string = '')
  if !s_enabled
    return
  endif
  # A commit, checkout or pull moves the branch as readily as the hunks, and a
  # `git init`, clone or submodule add moves where a buffer's repository even
  # begins -- so the remembered repository tokens go too.  This is the one
  # event that can invalidate them, and it is rare enough to pay for.  A
  # repository-scoped change cannot move any of those boundaries, so it keeps
  # the tokens.
  InvalidateBranches(repo_filter)
  if repo_filter ==# ''
    s_repo_token_cache = {}
  endif
  for win in getwininfo()
    if !IsFileBuffer(win.bufnr)
      continue
    endif
    if repo_filter !=# '' && BufRepoToken(win.bufnr) !=# repo_filter
      # Not this repository -- but a branch read that was on the wire when the
      # generation moved has been abandoned, so give it a chance to be re-asked
      # instead of leaving that buffer without a branch.
      EnsureBranch(win.bufnr)
      continue
    endif
    InvalidateBlame(win.bufnr)
    InvalidateHunks(win.bufnr)
    EnsureBranch(win.bufnr)
    RequestHunks(win.bufnr, 'signs', false)
  endfor
  ScheduleLineBlame()
enddef

# External git commands (commits, checkouts) invalidate blame and hunks
# silently; a focus regain or shell command is the cheapest signal we get.
export def OnExternalChange()
  # Disable is a hard lifecycle boundary: a leftover status scratch must not
  # restart the daemon on the next FocusGained.
  if !s_enabled
    return
  endif
  if ConfBool('simplegit_status_auto_refresh', true) && HasOpenStatus()
    ScheduleStatusRefresh()
  elseif !s_status_refresh_forced
    CancelStatusRefresh()
  endif
  RefreshVisibleGitState()
enddef

export def ToggleLineBlame()
  s_line_blame_on = !s_line_blame_on
  if s_line_blame_on
    ScheduleLineBlame()
    echo '[SimpleGit] line blame on'
  else
    ClearLineBlame(bufnr('%'))
    echo '[SimpleGit] line blame off'
  endif
enddef

# =============================================================
# Blame popup for the current line
# =============================================================
def BlamePopupText(sha: string, info: dict<any>): list<string>
  var when = get(info, 'time', 0)
  return [
    'Commit  ' .. ShortSha(sha),
    'Author  ' .. get(info, 'author', ''),
    'Date    ' .. (when > 0 ? strftime('%Y-%m-%d %H:%M', when) .. ' (' .. TimeAgo(when) .. ')' : ''),
    '',
    get(info, 'summary', ''),
  ]
enddef

def ShowPopup(text: list<string>)
  if has('popupwin')
    popup_atcursor(text, {
      padding: [0, 1, 0, 1],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      moved: 'any',
    })
  else
    echo join(text, ' | ')
  endif
enddef

def ShowBlamePopup(bufnr: number)
  if bufnr != bufnr('%')
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame) || get(blame, 'failed', false)
    Warn('no blame information for this buffer')
    return
  endif
  var lines = get(blame, 'lines', [])
  var lnum = line('.')
  if lnum > len(lines)
    Warn('line has no blame information (unsaved changes?)')
    return
  endif
  var sha = lines[lnum - 1]
  if sha ==# UNCOMMITTED
    echo '[SimpleGit] Uncommitted changes'
    return
  endif
  ShowPopup(BlamePopupText(sha, get(blame.commits, sha, {})))
enddef

def ShowLineBlamePopup(bufnr: number, lnum: number, sha: string, info: dict<any>)
  if bufnr != bufnr('%') || lnum != line('.')
    return
  endif
  if sha ==# UNCOMMITTED
    echo '[SimpleGit] Uncommitted changes'
    return
  endif
  if sha ==# ''
    Warn('line has no blame information')
    return
  endif
  ShowPopup(BlamePopupText(sha, info))
enddef

export def BlameLine()
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var blame = BlameFor(bufnr)
  if !empty(blame)
    ShowBlamePopup(bufnr)
    return
  endif
  # A modified buffer no longer matches the file on disk, so a line number is
  # not a safe thing to send: fall back to the whole-file request, which
  # reports the mismatch instead of asking git for a line that may not exist.
  if LineBlameSupported() && !getbufvar(bufnr, '&modified')
    var lnum = line('.')
    var cached = CachedLineBlame(bufnr, lnum)
    if !empty(cached)
      ShowLineBlamePopup(bufnr, lnum, get(cached, 'sha', ''), cached)
      return
    endif
    if !RequestLineBlame(bufnr, lnum, 'popup', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  if !RequestBlame(bufnr, 'popup', true)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Blame sidebar (whole file)
# =============================================================
def FindBlameWin(bufnr: number): number
  for win in getwininfo()
    if getbufvar(win.bufnr, 'simplegit_blame_src', -1) == bufnr
      return win.winid
    endif
  endfor
  return 0
enddef

def OpenBlameWindow(bufnr: number)
  if bufnr != bufnr('%') || !bufexists(bufnr)
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame) || get(blame, 'failed', false)
    Warn('no blame information for this buffer')
    return
  endif
  if getbufvar(bufnr, '&modified')
    Warn('save the buffer first; blame reflects the file on disk')
    return
  endif
  var existing = FindBlameWin(bufnr)
  if existing != 0
    win_gotoid(existing)
    return
  endif

  var lines = get(blame, 'lines', [])
  var commits = get(blame, 'commits', {})
  var display: list<string> = []
  var shas: list<string> = []
  for sha in lines
    shas->add(sha)
    if sha ==# UNCOMMITTED
      display->add('0000000 ~ uncommitted    ')
      continue
    endif
    var info = get(commits, sha, {})
    var author = strcharpart(get(info, 'author', ''), 0, 14)
    display->add(printf('%s %s %-14s', ShortSha(sha), CommitDate(get(info, 'time', 0)), author))
  endfor

  var src_win = win_getid()
  var src_top = line('w0')
  var src_lnum = line('.')
  setwinvar(src_win, '&scrollbind', 1)
  setwinvar(src_win, '&cursorbind', 1)

  var width = ConfNum('simplegit_blame_width', 34)
  silent keepalt vertical topleft new
  execute 'vertical resize ' .. width
  silent execute 'file ' .. fnameescape('simplegit://blame/' .. fnamemodify(bufname(bufnr), ':t'))
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nonumber norelativenumber nowrap nofoldenable foldcolumn=0 signcolumn=no
  setlocal winfixwidth
  setline(1, display)
  setlocal nomodifiable
  b:simplegit_blame_src = bufnr
  b:simplegit_shas = shas
  b:simplegit_src_win = src_win
  setlocal scrollbind cursorbind scrollopt=ver,jump

  syntax match SimpleGitBlameSha /^\x\{7}/
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/
  syntax match SimpleGitBlameUncommitted /^0\{7} \~ uncommitted.*/

  nnoremap <silent><buffer> <CR> <ScriptCmd>BlameWindowShow()<CR>
  nnoremap <silent><buffer> p <ScriptCmd>BlameWindowPopup()<CR>
  nnoremap <silent><buffer> q <ScriptCmd>CloseBlameWindow()<CR>

  # Align the sidebar with the source window before binding takes over.
  execute ':' .. src_lnum
  win_execute(src_win, 'normal! ' .. src_top .. 'zt')
  execute 'normal! ' .. src_top .. 'zt'
  execute ':' .. src_lnum
  syncbind
enddef

def BlameWindowSha(): string
  var shas = get(b:, 'simplegit_shas', [])
  var lnum = line('.')
  if lnum > len(shas)
    return ''
  endif
  return shas[lnum - 1]
enddef

def BlameWindowShow()
  var sha = BlameWindowSha()
  if sha ==# '' || sha ==# UNCOMMITTED
    Warn('no commit under cursor')
    return
  endif
  var src = get(b:, 'simplegit_blame_src', -1)
  var path = BufFilePath(src)
  if path ==# ''
    Warn('source buffer is gone')
    return
  endif
  var title = 'commit ' .. ShortSha(sha)
  var ctx = ViewContext('show', path, 'simplegit://' .. title)
  ctx.title = title
  if !Dispatch({type: 'show', path: path, rev: sha}, ctx)
    Warn('daemon unavailable')
  endif
enddef

def BlameWindowPopup()
  var sha = BlameWindowSha()
  if sha ==# '' || sha ==# UNCOMMITTED
    return
  endif
  var src = get(b:, 'simplegit_blame_src', -1)
  var blame = BlameFor(src)
  if empty(blame)
    return
  endif
  var info = get(get(blame, 'commits', {}), sha, {})
  var when = get(info, 'time', 0)
  var text = [
    'Commit  ' .. ShortSha(sha),
    'Author  ' .. get(info, 'author', ''),
    'Date    ' .. (when > 0 ? strftime('%Y-%m-%d %H:%M', when) : ''),
    '',
    get(info, 'summary', ''),
  ]
  if has('popupwin')
    popup_atcursor(text, {padding: [0, 1, 0, 1], moved: 'any'})
  else
    echo join(text, ' | ')
  endif
enddef

def CloseBlameWindow()
  var src_win = get(b:, 'simplegit_src_win', 0)
  var blame_win = win_getid()
  if src_win != 0 && win_id2win(src_win) > 0
    setwinvar(src_win, '&scrollbind', 0)
    setwinvar(src_win, '&cursorbind', 0)
  endif
  win_execute(blame_win, 'close')
enddef

export def ToggleBlame()
  var bufnr = bufnr('%')
  # Toggling from inside the sidebar closes it.
  if has_key(b:, 'simplegit_blame_src')
    CloseBlameWindow()
    return
  endif
  var existing = FindBlameWin(bufnr)
  if existing != 0
    win_gotoid(existing)
    CloseBlameWindow()
    return
  endif
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  if getbufvar(bufnr, '&modified')
    Warn('save the buffer first; blame reflects the file on disk')
    return
  endif
  var blame = BlameFor(bufnr)
  if !empty(blame) && !get(blame, 'failed', false)
    OpenBlameWindow(bufnr)
    return
  endif
  if !RequestBlame(bufnr, 'window', true)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Scratch windows (show / history / status)
# =============================================================
# The buffer carrying exactly this scratch name, or -1.  bufnr() matches a
# pattern rather than a literal, so confirm the name it found.
def ScratchBufnr(name: string): number
  var found = bufnr(name)
  return found > 0 && bufexists(found) && bufname(found) ==# name ? found : -1
enddef

# Reuse an existing window for this name instead of stacking splits -- but
# only inside the current tab.  getwininfo() enumerates every tab page, so
# following a same-named window would move the user out of the tab they are
# working in, which is exactly what an asynchronous reply must never do.  A
# scratch buffer owned by another tab is retired instead, because these names
# are unique by construction and :file refuses a duplicate.
#
# Whichever branch it takes, this returns an *empty* scratch buffer that is
# current in the current tab -- every caller writes its content with
# setline(1, ...) and relies on nothing surviving underneath.  A branch that
# returned a buffer still holding the previous text left the tail of that text
# glued below the new content; for the commit message that meant committing
# lines written for something else.  Unsaved text is protected by refusing the
# command that would discard it (see Commit()), never by handing a dirty
# buffer to a caller that assumes an empty one.
def OpenScratch(name: string, height: number): number
  var existing = ScratchBufnr(name)
  for win in getwininfo()
    if win.bufnr == existing && win.tabnr == tabpagenr()
      win_gotoid(win.winid)
      setlocal modifiable
      silent :%delete _
      if height > 0
        execute 'resize ' .. height
      endif
      return bufnr('%')
    endif
  endfor
  if existing > 0
    silent execute 'bwipeout! ' .. existing
  endif
  silent keepalt botright new
  if height > 0
    execute 'resize ' .. height
  endif
  silent execute 'file ' .. fnameescape(name)
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nonumber norelativenumber nofoldenable foldcolumn=0 signcolumn=no
  nnoremap <silent><buffer> q <Cmd>close<CR>
  return bufnr('%')
enddef

# Every asynchronously opened view carries the window that asked for it, the
# repository it describes and a latest-wins generation.  Without this a slow
# `show`/`log`/`history`/`cat` reply opens its split in whatever window happens
# to be current when it lands -- pulling the user into another tab, which the
# status path has guarded against for a while and these paths had not.
def ViewContext(kind: string, path: string, target: string): dict<any>
  s_view_generation += 1
  if len(s_view_latest) >= 64 && !has_key(s_view_latest, target)
    remove(s_view_latest, keys(s_view_latest)[0])
  endif
  s_view_latest[target] = s_view_generation
  var dir = path ==# '' ? getcwd()
    : isdirectory(path) ? path : PathDir(path)
  return {
    kind: kind,
    interactive: true,
    origin_tabnr: tabpagenr(),
    origin_winid: win_getid(),
    origin_bufnr: bufnr('%'),
    repo_token: RepoToken(dir),
    view_target: target,
    view_generation: s_view_generation,
  }
enddef

def ViewStillWanted(ctx: dict<any>): bool
  var target = get(ctx, 'view_target', '')
  if target ==# ''
    # A request issued before this guard existed; nothing to check.
    return true
  endif
  if get(s_view_latest, target, -2) != get(ctx, 'view_generation', -1)
    DebugLog('discarded superseded ' .. get(ctx, 'kind', 'view') .. ' reply')
    return false
  endif
  remove(s_view_latest, target)
  if !OriginStillCurrent(ctx)
    DebugLog('discarded ' .. get(ctx, 'kind', 'view') .. ' reply after its origin changed')
    return false
  endif
  # The origin window may still be current while showing a different file --
  # and possibly a different repository -- than the one this reply describes.
  var origin_path = BufFilePath(get(ctx, 'origin_bufnr', -1))
  if origin_path !=# ''
        && RepoToken(PathDir(origin_path)) !=# get(ctx, 'repo_token', '')
    DebugLog('discarded ' .. get(ctx, 'kind', 'view') .. ' reply after its repository changed')
    return false
  endif
  return true
enddef

def OnShow(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', v:null)
  if type(lines) != v:t_list
    DebugLog('ignored malformed show response')
    return
  endif
  if !ViewStillWanted(ctx)
    return
  endif
  var title = get(ctx, 'title', 'show')
  OpenScratch('simplegit://' .. title, 0)
  setlocal filetype=git
  setline(1, empty(lines) ? ['(empty)'] : lines)
  setlocal nomodifiable
  execute ':1'
enddef

export def Show(rev: string)
  var use_rev = rev ==# '' ? 'HEAD' : rev
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    path = getcwd()
  endif
  var title = 'commit ' .. use_rev
  var ctx = ViewContext('show', path, 'simplegit://' .. title)
  ctx.title = title
  if !Dispatch({type: 'show', path: path, rev: use_rev}, ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# File history
# =============================================================
def ValidLogEntry(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'sha', v:null)) == v:t_string
        \ && type(get(entry, 'author', v:null)) == v:t_string
        \ && type(get(entry, 'time', v:null)) == v:t_number
        \ && type(get(entry, 'subject', v:null)) == v:t_string
enddef

def OnLog(ctx: dict<any>, ev: dict<any>)
  var entries = get(ev, 'entries', v:null)
  if type(entries) != v:t_list
    DebugLog('ignored malformed log response')
    return
  endif
  if !ViewStillWanted(ctx)
    return
  endif
  var path = get(ctx, 'path', '')
  if empty(entries)
    Warn('no history for ' .. fnamemodify(path, ':t'))
    return
  endif
  var display: list<string> = []
  var shas: list<string> = []
  for entry in entries
    if !ValidLogEntry(entry)
      continue
    endif
    shas->add(entry.sha)
    display->add(printf('%s %s %-16s %s',
      ShortSha(entry.sha), CommitDate(entry.time),
      strcharpart(entry.author, 0, 16), entry.subject))
  endfor
  var height = min([max([len(display), 5]), ConfNum('simplegit_history_height', 15)])
  OpenScratch('simplegit://history/' .. fnamemodify(path, ':t'), height)
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_shas = shas
  b:simplegit_src_path = path

  syntax match SimpleGitBlameSha /^\x\{7}/
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/

  nnoremap <silent><buffer> <CR> <ScriptCmd>HistoryShow(false)<CR>
  nnoremap <silent><buffer> a <ScriptCmd>HistoryShow(true)<CR>
  execute ':1'
enddef

def HistoryShow(whole_commit: bool)
  var shas = get(b:, 'simplegit_shas', [])
  var path = get(b:, 'simplegit_src_path', '')
  var lnum = line('.')
  if lnum > len(shas) || path ==# ''
    return
  endif
  var sha = shas[lnum - 1]
  var req = {type: 'show', path: path, rev: sha}
  if !whole_commit
    req.file = path
  endif
  var title = 'commit ' .. ShortSha(sha)
  var ctx = ViewContext('show', path, 'simplegit://' .. title)
  ctx.title = title
  if !Dispatch(req, ctx)
    Warn('daemon unavailable')
  endif
enddef

export def History()
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var limit = ConfNum('simplegit_history_limit', 200)
  var ctx = ViewContext('log', path,
    'simplegit://history/' .. fnamemodify(path, ':t'))
  ctx.path = path
  if !Dispatch({type: 'log', path: path, limit: limit}, ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Repository-wide commit graph
# =============================================================
def ValidGraphRow(row: any): bool
  return type(row) == v:t_dict
        \ && type(get(row, 'graph', v:null)) == v:t_string
        \ && type(get(row, 'sha', v:null)) == v:t_string
        \ && type(get(row, 'date', v:null)) == v:t_string
        \ && type(get(row, 'author', v:null)) == v:t_string
        \ && type(get(row, 'refs', v:null)) == v:t_string
        \ && type(get(row, 'subject', v:null)) == v:t_string
enddef

def GraphRowDisplay(row: dict<any>): string
  if row.sha ==# ''
    return row.graph
  endif
  var refs = row.refs ==# '' ? '' : '(' .. row.refs .. ') '
  return printf('%s%s %s %-14.14s %s%s',
    row.graph, row.sha, row.date, row.author, refs, row.subject)
enddef

def OnGraphLog(ctx: dict<any>, ev: dict<any>)
  var rows = get(ev, 'rows', v:null)
  if type(rows) != v:t_list
    DebugLog('ignored malformed graph_log response')
    return
  endif
  var path = get(ctx, 'path', '')
  var append_mode = get(ctx, 'append', false)
  if !append_mode && !ViewStillWanted(ctx)
    return
  endif
  var display: list<string> = []
  var shas: list<string> = []
  for row in rows
    if !ValidGraphRow(row)
      continue
    endif
    shas->add(row.sha)
    display->add(GraphRowDisplay(row))
  endfor
  if empty(display) && !append_mode
    Warn('no commits found')
    return
  endif

  if append_mode
    var buf = get(ctx, 'bufnr', -1)
    var win = bufwinid(buf)
    if win == -1
      return
    endif
    if empty(display)
      Warn('no more commits')
      return
    endif
    # win_execute() rather than win_gotoid(): paging appends to a window that
    # may by now live in another tab, and reaching it must not take the user
    # there.
    win_execute(win, 'setlocal modifiable')
    appendbufline(buf, '$', display)
    win_execute(win, 'setlocal nomodifiable')
    setbufvar(buf, 'simplegit_graph_shas',
      getbufvar(buf, 'simplegit_graph_shas', [])->copy()->extend(shas))
    setbufvar(buf, 'simplegit_graph_skip',
      getbufvar(buf, 'simplegit_graph_skip', 0)
        + len(filter(copy(shas), (_, sha) => sha !=# '')))
    return
  endif

  var height = min([max([len(display), 5]), ConfNum('simplegit_log_height', 20)])
  OpenScratch('simplegit://log', height)
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_graph_shas = shas
  b:simplegit_graph_skip = len(filter(copy(shas), (_, sha) => sha !=# ''))
  b:simplegit_src_path = path

  syntax match SimpleGitLogGraph /^[ |\/\\*_.-]*/
  syntax match SimpleGitLogSha /^[ |\/\\*_.-]*\zs\x\{7,}\ze /
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/
  syntax match SimpleGitLogRefs /([^)]\+)/
  highlight default link SimpleGitLogGraph Comment
  highlight default link SimpleGitLogSha Identifier
  highlight default link SimpleGitLogRefs Special

  nnoremap <silent><buffer> <CR> <ScriptCmd>GraphLogShow()<CR>
  nnoremap <silent><buffer> m <ScriptCmd>GraphLogMore()<CR>
  execute ':1'
enddef

def GraphLogShow()
  var shas = get(b:, 'simplegit_graph_shas', [])
  var path = get(b:, 'simplegit_src_path', '')
  var lnum = line('.')
  if lnum > len(shas) || path ==# ''
    return
  endif
  var sha = shas[lnum - 1]
  if sha ==# ''
    return
  endif
  var title = 'commit ' .. sha
  var ctx = ViewContext('show', path, 'simplegit://' .. title)
  ctx.title = title
  if !Dispatch({type: 'show', path: path, rev: sha}, ctx)
    Warn('daemon unavailable')
  endif
enddef

def GraphLogMore()
  var path = get(b:, 'simplegit_src_path', '')
  if path ==# ''
    return
  endif
  var limit = ConfNum('simplegit_log_limit', 200)
  var skip = get(b:, 'simplegit_graph_skip', 0)
  if !Dispatch({type: 'graph_log', path: path, limit: limit, skip: skip},
      {kind: 'graph_log', interactive: true, path: path,
       append: true, bufnr: bufnr('%')})
    Warn('daemon unavailable')
  endif
enddef

export def Log()
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    path = getcwd()
  endif
  var limit = ConfNum('simplegit_log_limit', 200)
  var ctx = ViewContext('graph_log', path, 'simplegit://log')
  ctx.path = path
  if !Dispatch({type: 'graph_log', path: path, limit: limit, skip: 0}, ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Diff against a revision
# =============================================================
def OnCat(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', v:null)
  if type(lines) != v:t_list
    DebugLog('ignored malformed cat response')
    return
  endif
  if !ViewStillWanted(ctx)
    return
  endif
  var src = get(ctx, 'bufnr', -1)
  var rev = get(ctx, 'rev', 'HEAD')
  if !bufexists(src)
    return
  endif
  var src_win = bufwinid(src)
  if src_win == -1
    Warn('source window is gone')
    return
  endif
  win_gotoid(src_win)
  var src_ft = &filetype
  diffthis
  execute 'silent keepalt vertical leftabove new'
  silent execute 'file ' .. fnameescape('simplegit://' .. rev .. '/' .. fnamemodify(bufname(src), ':t'))
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setline(1, lines)
  setlocal nomodifiable
  execute 'setlocal filetype=' .. fnameescape(src_ft)
  b:simplegit_diff_src = src
  diffthis
  nnoremap <silent><buffer> q <ScriptCmd>CloseDiff()<CR>
  win_gotoid(src_win)
enddef

def CloseDiff()
  var src = get(b:, 'simplegit_diff_src', -1)
  close
  if bufexists(src)
    var src_win = bufwinid(src)
    if src_win != -1
      win_execute(src_win, 'diffoff')
    endif
  endif
enddef

export def Diff(rev: string)
  var bufnr = bufnr('%')
  var path = BufFilePath(bufnr)
  if path ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var use_rev = rev ==# '' ? 'HEAD' : rev
  var ctx = ViewContext('cat', path, 'simplegit://diff/' .. bufnr)
  ctx.bufnr = bufnr
  ctx.rev = use_rev
  if !Dispatch({type: 'cat', path: path, rev: use_rev}, ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Hunks — signs, navigation, preview, stage and undo
# =============================================================
def SignsEnabled(): bool
  return s_signs_on && ConfBool('simplegit_signs', true) && has('signs')
enddef

def EnsureSignDefs()
  if s_signs_defined
    return
  endif
  sign_define('SimpleGitAdd', {
    text: get(g:, 'simplegit_sign_added', '+'),
    texthl: 'SimpleGitSignAdd',
  })
  sign_define('SimpleGitChange', {
    text: get(g:, 'simplegit_sign_changed', '~'),
    texthl: 'SimpleGitSignChange',
  })
  sign_define('SimpleGitDelete', {
    text: get(g:, 'simplegit_sign_removed', '_'),
    texthl: 'SimpleGitSignDelete',
  })
  s_signs_defined = true
enddef

def ValidHunk(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'old_start', v:null)) == v:t_number
        \ && type(get(entry, 'old_count', v:null)) == v:t_number
        \ && type(get(entry, 'new_start', v:null)) == v:t_number
        \ && type(get(entry, 'new_count', v:null)) == v:t_number
        \ && type(get(entry, 'lines', v:null)) == v:t_list
enddef

def HunksFor(bufnr: number): list<dict<any>>
  var cached = get(s_hunk_cache, string(bufnr), {})
  if empty(cached) || get(cached, 'failed', false)
    return []
  endif
  return get(cached, 'hunks', [])
enddef

def InvalidateHunks(bufnr: number)
  var key = string(bufnr)
  if has_key(s_hunk_cache, key)
    remove(s_hunk_cache, key)
  endif
  if has_key(s_hunk_stale, key)
    remove(s_hunk_stale, key)
  endif
enddef

# The buffer line a hunk anchors on: its first changed line, or for pure
# deletions the line the change happened after.
def HunkLine(hunk: dict<any>): number
  return max([hunk.new_start, 1])
enddef

# Whether a hunk shows up anywhere in the buffer lines first..last.  A pure
# deletion has no lines of its own, so it counts as touched only through the
# anchor line its sign sits on -- the same rule the daemon applies when it
# picks hunks out of a diff, and they have to agree or a selection would
# preview one set of hunks and stage another.
def HunkTouches(hunk: dict<any>, first: number, last: number): bool
  if hunk.new_count == 0
    return HunkLine(hunk) >= first && HunkLine(hunk) <= last
  endif
  return hunk.new_start <= last && hunk.new_start + hunk.new_count - 1 >= first
enddef

def HunkCovers(hunk: dict<any>, lnum: number): bool
  return HunkTouches(hunk, lnum, lnum)
enddef

# The sign name wanted on each line, as a dict lnum -> name.
def DesiredSigns(bufnr: number): dict<string>
  var want: dict<string> = {}
  if !SignsEnabled()
    return want
  endif
  var hunks = HunksFor(bufnr)
  if empty(hunks)
    return want
  endif
  var max_signs = ConfNum('simplegit_max_signs', 500)
  var last = get(get(getbufinfo(bufnr), 0, {}), 'linecount', 0)
  var total = 0
  for hunk in hunks
    if hunk.new_count == 0
      want[string(min([HunkLine(hunk), max([last, 1])]))] = 'SimpleGitDelete'
      total += 1
      continue
    endif
    var name = hunk.old_count == 0 ? 'SimpleGitAdd' : 'SimpleGitChange'
    for lnum in range(hunk.new_start, hunk.new_start + hunk.new_count - 1)
      if lnum > last
        break
      endif
      want[string(lnum)] = name
      total += 1
    endfor
  endfor
  if total > max_signs
    DebugLog('not placing ' .. total .. ' signs (over simplegit_max_signs)')
    return {}
  endif
  return want
enddef

# Update signs in place: unplacing everything and starting over makes the
# whole column flicker on every live refresh.
def PlaceSigns(bufnr: number)
  if !bufexists(bufnr) || !has('signs')
    return
  endif
  var want = DesiredSigns(bufnr)
  var priority = ConfNum('simplegit_sign_priority', 10)
  var keep: dict<bool> = {}
  var to_remove: list<dict<any>> = []
  for sign in get(get(sign_getplaced(bufnr, {group: SIGN_GROUP}), 0, {}), 'signs', [])
    var key = string(sign.lnum)
    if get(want, key, '') ==# sign.name && !has_key(keep, key)
      keep[key] = true
    else
      to_remove->add({buffer: bufnr, group: SIGN_GROUP, id: sign.id})
    endif
  endfor
  var to_add: list<dict<any>> = []
  for [key, name] in items(want)
    if !has_key(keep, key)
      to_add->add({buffer: bufnr, group: SIGN_GROUP, priority: priority,
        name: name, lnum: str2nr(key)})
    endif
  endfor
  if !empty(to_remove)
    sign_unplacelist(to_remove)
  endif
  if !empty(to_add)
    EnsureSignDefs()
    sign_placelist(to_add)
  endif
enddef

# Buffer text exactly as it would be written to disk, for the live diff.
def BufferText(bufnr: number): string
  var eol = getbufvar(bufnr, '&endofline') ? 1 : 0
  var ff = getbufvar(bufnr, '&fileformat')
  var sep = ff ==# 'dos' ? "\r\n" : ff ==# 'mac' ? "\r" : "\n"
  return join(getbufline(bufnr, 1, '$'), sep) .. (eol == 1 ? sep : '')
enddef

def RequestHunks(bufnr: number, purpose: string, interactive: bool): bool
  var path = BufFilePath(bufnr)
  if path ==# ''
    return false
  endif
  var key = string(bufnr)
  if has_key(s_hunk_inflight, key)
    if purpose ==# 'signs'
      # Answer in flight already; rerun once it lands so the last edit wins.
      s_hunk_stale[key] = true
    else
      # A jump or preview must not be dropped on the floor.  BufReadPost puts
      # a refresh in flight, so without this the first ]g after opening a
      # buffer did nothing at all -- no jump, no message, keypress gone.
      s_hunk_pending_action[key] = purpose
    endif
    return true
  endif
  var req: dict<any> = {type: 'hunks', path: path}
  if getbufvar(bufnr, '&modified')
    var text = BufferText(bufnr)
    if len(text) > ConfNum('simplegit_live_max_bytes', 1024 * 1024)
      return false
    endif
    req.content = text
  endif
  var ok = Dispatch(req,
    {kind: 'hunks', bufnr: bufnr, purpose: purpose, interactive: interactive})
  if ok
    s_hunk_inflight[key] = true
  endif
  return ok
enddef

def OnHunks(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var key = string(bufnr)
  if has_key(s_hunk_inflight, key)
    remove(s_hunk_inflight, key)
  endif
  var hunks = get(ev, 'hunks', v:null)
  if type(hunks) != v:t_list
    DebugLog('ignored malformed hunks response')
    return
  endif
  if !bufexists(bufnr)
    return
  endif
  var valid: list<dict<any>> = []
  for entry in hunks
    if ValidHunk(entry)
      valid->add(entry)
    endif
  endfor
  if len(s_hunk_cache) >= 64 && !has_key(s_hunk_cache, key)
    remove(s_hunk_cache, keys(s_hunk_cache)[0])
  endif
  s_hunk_cache[key] = {failed: false, hunks: valid}
  PlaceSigns(bufnr)
  PublishStatusDict(bufnr)
  var purpose = get(ctx, 'purpose', 'signs')
  if has_key(s_hunk_pending_action, key)
    # Something was pressed while this request was in flight; the later press
    # wins, exactly as it would have without the race.
    purpose = remove(s_hunk_pending_action, key)
  endif
  if purpose ==# 'preview'
    ShowHunkPreview(bufnr)
  elseif purpose ==# 'next'
    JumpHunk(bufnr, 1)
  elseif purpose ==# 'prev'
    JumpHunk(bufnr, -1)
  endif
  if has_key(s_hunk_stale, key)
    remove(s_hunk_stale, key)
    RequestHunks(bufnr, 'signs', false)
  endif
enddef

def OnHunkOp(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var action = get(ev, 'action', '')
  if !bufexists(bufnr)
    return
  endif
  if action ==# 'undo'
    # The daemon rewrote the file on disk; pick the change up. A plain
    # checktime only reloads with 'autoread', so re-edit when it is safe.
    if bufnr == bufnr('%') && !getbufvar(bufnr, '&modified')
      var view = winsaveview()
      silent! execute 'edit!'
      winrestview(view)
    else
      silent! execute 'checktime ' .. bufnr
    endif
    InvalidateBlame(bufnr)
    ScheduleLineBlame()
  endif
  InvalidateHunks(bufnr)
  RequestHunks(bufnr, 'signs', false)
  # The daemon does not count what it applied, but the caller knows whether it
  # asked about one line or a selection, and "hunk staged" after selecting ten
  # of them reads like only one was taken.
  var subject = get(ctx, 'ranged', false) ? 'hunks' : 'hunk'
  echo '[SimpleGit] ' .. subject .. (action ==# 'undo' ? ' reverted' : ' staged')
enddef

def JumpHunk(bufnr: number, direction: number)
  if bufnr != bufnr('%')
    return
  endif
  var hunks = HunksFor(bufnr)
  if empty(hunks)
    Warn('no hunks in this buffer')
    return
  endif
  var lnum = line('.')
  var target = 0
  if direction > 0
    for hunk in hunks
      if HunkLine(hunk) > lnum
        target = HunkLine(hunk)
        break
      endif
    endfor
  else
    for hunk in reverse(copy(hunks))
      if HunkLine(hunk) < lnum
        target = HunkLine(hunk)
        break
      endif
    endfor
  endif
  if target == 0
    Warn(direction > 0 ? 'no next hunk' : 'no previous hunk')
    return
  endif
  normal! m'
  cursor(target, 1)
enddef

# The range a preview was asked for, kept across the wait for a hunks reply:
# bufnr (string) -> [first, last].  Without it a preview requested over a
# selection would come back as a preview of whatever line the cursor sits on.
var s_hunk_preview_range: dict<list<number>> = {}

def ShowHunkPreview(bufnr: number)
  if bufnr != bufnr('%')
    return
  endif
  var key = string(bufnr)
  var range = has_key(s_hunk_preview_range, key)
    ? remove(s_hunk_preview_range, key)
    : [line('.'), line('.')]
  var lines: list<string> = []
  for hunk in HunksFor(bufnr)
    if HunkTouches(hunk, range[0], range[1])
      lines->extend(hunk.lines)
    endif
  endfor
  if empty(lines)
    Warn(range[0] == range[1] ? 'no hunk under cursor' : 'no hunk in the selection')
    return
  endif
  if has('popupwin')
    var winid = popup_atcursor(lines, {
      padding: [0, 1, 0, 1],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      moved: 'any',
      maxheight: 20,
    })
    win_execute(winid, 'setlocal filetype=diff')
  else
    echo join(lines, "\n")
  endif
enddef

# Shared entry guard: hunk features need a readable, unmodified file.
def HunkTarget(need_saved: bool): number
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return -1
  endif
  if need_saved && getbufvar(bufnr, '&modified')
    Warn('save the buffer first; hunks reflect the file on disk')
    return -1
  endif
  return bufnr
enddef

export def HunkNext()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'next', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  JumpHunk(bufnr, 1)
enddef

export def HunkPrev()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'prev', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  JumpHunk(bufnr, -1)
enddef

# The lines a hunk command applies to.  Commands are declared -range, so with
# no range given Vim passes the cursor line as both ends, and a zero means the
# caller (a <Plug> map, a script) did not go through a command at all.
def HunkRange(first: number, last: number): list<number>
  var start = first > 0 ? first : line('.')
  var finish = last > 0 ? last : start
  return start <= finish ? [start, finish] : [finish, start]
enddef

export def HunkPreview(first: number = 0, last: number = 0)
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  var range = HunkRange(first, last)
  s_hunk_preview_range[string(bufnr)] = range
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'preview', true)
      remove(s_hunk_preview_range, string(bufnr))
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  ShowHunkPreview(bufnr)
enddef

def HunkOperate(op: string, first: number, last: number)
  var bufnr = HunkTarget(true)
  if bufnr < 0
    return
  endif
  var hunks = HunksFor(bufnr)
  if !empty(get(s_hunk_cache, string(bufnr), {})) && empty(hunks)
    Warn('no hunks in this buffer')
    return
  endif
  var range = HunkRange(first, last)
  var ranged = range[0] != range[1]
  var req: dict<any> = {type: op, path: BufFilePath(bufnr), lnum: range[0]}
  var ctx: dict<any> = {kind: 'hunk_op', bufnr: bufnr, interactive: true,
    ranged: ranged}
  if ranged
    req.last_lnum = range[1]
    # Fail closed rather than quietly narrowing: a daemon that predates hunk
    # ranges ignores last_lnum and would stage only the hunk on the first line
    # of the selection, which is neither what was asked for nor visible as a
    # failure.
    ctx.requires_capability = CAP_HUNK_RANGE
  endif
  if !Dispatch(req, ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

export def HunkStage(first: number = 0, last: number = 0)
  HunkOperate('stage', first, last)
enddef

export def HunkUndo(first: number = 0, last: number = 0)
  HunkOperate('undo', first, last)
enddef

# The `ih` / `ah` text objects: select the hunk the cursor sits in, linewise.
# `around` additionally takes the blank lines directly below it, so `dah` on a
# newly added paragraph leaves no gap behind.
#
# Text objects cannot wait for anything, so this answers from the cached hunks
# alone and says so when they are not there yet, rather than selecting the
# wrong lines or leaving the operator hanging on a request.
export def SelectHunk(around: bool = false)
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    RequestHunks(bufnr, 'signs', false)
    Warn('hunks not loaded yet for this buffer')
    return
  endif
  var lnum = line('.')
  for hunk in HunksFor(bufnr)
    if !HunkCovers(hunk, lnum)
      continue
    endif
    var first = HunkLine(hunk)
    # A pure deletion has no lines in the buffer at all; its anchor is the only
    # honest selection, and it is what the sign points at.
    var last = hunk.new_count == 0
      ? first
      : min([hunk.new_start + hunk.new_count - 1, line('$')])
    if around
      while last < line('$') && getline(last + 1) =~# '^\s*$'
        last += 1
      endwhile
    endif
    execute 'normal! ' .. first .. 'GV' .. last .. 'G'
    return
  endfor
  Warn('no hunk under cursor')
enddef

# `reloaded` is set from BufReadPost, which fires when a buffer is re-read from
# disk: `:edit!` to throw an edit away, the reload after a hunk revert,
# 'autoread' picking up an external checkout.  The cached hunks describe the
# text that was just replaced, and without dropping them this function takes
# the "already answered" branch below and repaints those stale signs.  A reload
# also fires TextChanged, so the debounce in ScheduleHunks() usually re-asks
# about g:simplegit_hunk_delay later and the wrong signs correct themselves --
# but only where there are timers, and only if the buffer is still current when
# one fires, since it refreshes bufnr('%') at that moment.  Leave the buffer
# before then and nothing asks again: every later BufEnter repaints the cache.
export def RefreshHunks(reloaded: bool = false)
  if !s_enabled
    return
  endif
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    return
  endif
  if reloaded
    InvalidateHunks(bufnr)
    InvalidateBlame(bufnr)
    ScheduleLineBlame()
  endif
  # The statusline API publishes a branch even where the sign column is off --
  # and b:simplegit_status_dict with it.  Publishing only from the hunk reply
  # left every buffer after the first without the variable whenever
  # g:simplegit_signs is 0: no hunks are ever requested then, and the one
  # branch reply that would have published it had already landed.
  EnsureBranch(bufnr)
  EnsureWatch(bufnr)
  PublishStatusDict(bufnr)
  if !SignsEnabled()
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    RequestHunks(bufnr, 'signs', false)
  else
    PlaceSigns(bufnr)
  endif
enddef

# Debounced follow-up while typing: diff the unsaved buffer so the signs
# track the edit instead of the file on disk.
export def ScheduleHunks()
  if !s_enabled || !SignsEnabled() || !has('timers')
    return
  endif
  if s_hunk_timer != 0
    timer_stop(s_hunk_timer)
  endif
  # A remote live diff reads the index through the workspace transport (two
  # round trips) before diffing locally; give the typing more rest first.
  var delay = BufIsRemote(bufnr('%'))
    ? ConfNum('simplegit_remote_hunk_delay', 750)
    : ConfNum('simplegit_hunk_delay', 300)
  s_hunk_timer = timer_start(delay, (_) => {
    s_hunk_timer = 0
    var bufnr = bufnr('%')
    if get(get(s_hunk_cache, string(bufnr), {}), 'failed', false)
      # Outside a repository or untracked; do not hammer the daemon per edit.
      return
    endif
    RequestHunks(bufnr, 'signs', false)
  })
enddef

export def ToggleSigns()
  s_signs_on = !s_signs_on
  if s_signs_on
    RefreshHunks()
    echo '[SimpleGit] signs on'
  else
    if has('signs')
      sign_unplace(SIGN_GROUP)
    endif
    echo '[SimpleGit] signs off'
  endif
enddef

# =============================================================
# Repository status
# =============================================================
def RepoToken(dir: string): string
  if IsRemotePath(dir)
    # A remote directory: there is no local filesystem to walk for a .git
    # marker, and asking the daemon would make every cache lookup a round
    # trip.  So each remote directory is its own repository as far as the
    # caches are concerned -- the same conservative identity a marker-less
    # local path gets below -- under the remote:// namespace, so a remote
    # checkout at /home/me/proj can never share a branch or a watch with a
    # local one at the same path.
    var plain = substitute(RemotePlainPath(dir), '/\+$', '', '')
    return REMOTE_PREFIX .. plain .. '/'
  endif
  # Match git -C's physical-path semantics without spawning Git on every UI
  # callback.  The nearest .git directory or gitfile distinguishes ordinary
  # worktrees, linked worktrees and submodules; a marker-less path keeps the
  # previous conservative absolute-directory identity.
  var full = fnamemodify(dir, ':p')
  if full ==# ''
    return ''
  endif
  var resolved = resolve(full)
  if !isdirectory(resolved)
    return fnamemodify(resolved ==# '' ? full : resolved, ':p')
  endif
  # :p preserves a trailing separator for directories.  :p:h removes exactly
  # that separator (while retaining /), so repeated :h calls walk ancestors.
  var current = fnamemodify(resolved, ':p:h')
  var fallback = fnamemodify(current, ':p')
  while current !=# ''
    var marker = current .. '/.git'
    if isdirectory(marker) || filereadable(marker)
      return fnamemodify(current, ':p')
    endif
    var parent = fnamemodify(current, ':h')
    if parent ==# current
      break
    endif
    current = parent
  endwhile
  return fallback
enddef

def StatusPathAt(bufnr: number, lnum: number): string
  if bufnr <= 0 || !bufexists(bufnr) || lnum <= 1
    return ''
  endif
  var raw_paths = getbufvar(bufnr, 'simplegit_paths', [])
  if type(raw_paths) != v:t_list || lnum > len(raw_paths)
    return ''
  endif
  var raw_path = raw_paths[lnum - 1]
  return type(raw_path) == v:t_string ? raw_path : ''
enddef

def RequestContext(kind: string, dir: string, lnum: number): dict<any>
  var repo = RepoToken(dir)
  var ctx: dict<any> = {
    kind: kind,
    interactive: true,
    dir: dir,
    repo_token: repo,
    lnum: lnum,
    origin_tabnr: tabpagenr(),
    origin_winid: win_getid(),
    origin_bufnr: bufnr('%'),
  }
  # A completion may refresh only the exact status view that initiated it.
  # Commands issued from ordinary file buffers deliberately carry no target,
  # so their eventual reply can never open a surprise status split.
  if bufname('%') ==# STATUS_BUF
        && get(b:, 'simplegit_repo_token', RepoToken(get(b:, 'simplegit_dir', ''))) ==# repo
    ctx.status_tabnr = tabpagenr()
    ctx.status_winid = win_getid()
    ctx.status_bufnr = bufnr('%')
    ctx.status_cursor_path = StatusPathAt(bufnr('%'), lnum)
  endif
  return ctx
enddef

def OriginStillCurrent(ctx: dict<any>): bool
  return tabpagenr() == get(ctx, 'origin_tabnr', tabpagenr())
        && win_getid() == get(ctx, 'origin_winid', win_getid())
        && bufnr('%') == get(ctx, 'origin_bufnr', bufnr('%'))
enddef

def InitialStatusContext(dir: string): dict<any>
  var initial_line = bufname('%') ==# STATUS_BUF ? line('.') : 1
  var ctx = RequestContext('status', dir, initial_line)
  # Explicit opens and in-place refreshes share the target buffer's generation
  # clock. Reserve the explicit request before it goes on the wire, so any
  # already-in-flight refresh becomes stale; a later refresh will in turn
  # advance the same clock and supersede this initial response.
  var existing = bufnr(STATUS_BUF)
  if existing > 0 && bufexists(existing)
    ctx.status_generation_bufnr = existing
    ctx.status_generation = NextStatusGeneration(existing)
  endif
  s_status_request_generation += 1
  var request_key = string(ctx.origin_winid) .. ':' .. string(ctx.origin_bufnr)
        .. ':' .. ctx.repo_token
  ctx.status_request_key = request_key
  ctx.status_request_generation = s_status_request_generation
  if len(s_status_latest) >= 128 && !has_key(s_status_latest, request_key)
    remove(s_status_latest, keys(s_status_latest)[0])
  endif
  s_status_latest[request_key] = s_status_request_generation
  return ctx
enddef

def NextStatusGeneration(bufnr: number): number
  var old = getbufvar(bufnr, 'simplegit_status_generation', 0)
  var generation = type(old) == v:t_number ? old + 1 : 1
  setbufvar(bufnr, 'simplegit_status_generation', generation)
  return generation
enddef

def ValidStatusTarget(ctx: dict<any>, dir: string): bool
  var winid = get(ctx, 'status_winid', 0)
  var bufnr = get(ctx, 'status_bufnr', 0)
  if type(winid) != v:t_number || type(bufnr) != v:t_number
        || winid <= 0 || bufnr <= 0 || !bufexists(bufnr)
    return false
  endif
  var infos = getwininfo(winid)
  if len(infos) != 1 || get(infos[0], 'bufnr', -1) != bufnr
        || bufname(bufnr) !=# STATUS_BUF
    return false
  endif
  # winid/bufnr are stable identities. tabnr is retained for diagnostics but
  # must not participate here: closing an earlier tab renumbers a still-live
  # target, while winid continues to identify it exactly.
  var repo = get(ctx, 'repo_token', RepoToken(dir))
  if getbufvar(bufnr, 'simplegit_repo_token', '') !=# repo
    return false
  endif
  var generation = get(ctx, 'status_generation', 0)
  return generation <= 0
        || getbufvar(bufnr, 'simplegit_status_generation', 0) == generation
enddef

def StatusRefreshContext(source: dict<any>, dir: string, lnum: number): dict<any>
  var bufnr = get(source, 'status_bufnr', 0)
  var cursor_path = get(source, 'status_cursor_path', '')
  if type(cursor_path) != v:t_string || cursor_path ==# ''
    cursor_path = StatusPathAt(bufnr, lnum)
  endif
  var ctx: dict<any> = {
    kind: 'status',
    interactive: false,
    refresh_only: true,
    dir: dir,
    repo_token: get(source, 'repo_token', RepoToken(dir)),
    lnum: lnum,
    origin_tabnr: get(source, 'origin_tabnr', 0),
    origin_winid: get(source, 'origin_winid', 0),
    origin_bufnr: get(source, 'origin_bufnr', 0),
    status_tabnr: get(source, 'status_tabnr', 0),
    status_winid: get(source, 'status_winid', 0),
    status_bufnr: bufnr,
    status_generation: NextStatusGeneration(bufnr),
    status_cursor_path: cursor_path,
  }
  return ctx
enddef

def CancelStatusRefresh()
  if s_status_refresh_timer != 0
    timer_stop(s_status_refresh_timer)
    s_status_refresh_timer = 0
  endif
  s_status_refresh_forced = false
  s_status_refresh_repo_filter = ''
  s_status_refresh_excluded_repos = {}
enddef

def RefreshOpenStatus(repo_filter: string = '', excluded_repos: dict<bool> = {},
    remote_only: bool = false)
  var seen: dict<bool> = {}
  for win in getwininfo()
    if bufname(win.bufnr) !=# STATUS_BUF || has_key(seen, string(win.bufnr))
      continue
    endif
    var dir = getbufvar(win.bufnr, 'simplegit_dir', '')
    var repo = getbufvar(win.bufnr, 'simplegit_repo_token', '')
    if type(dir) != v:t_string || dir ==# ''
          || type(repo) != v:t_string || repo ==# ''
      continue
    endif
    if (repo_filter !=# '' && repo !=# repo_filter)
          || has_key(excluded_repos, repo)
          || (remote_only && !IsRemotePath(dir))
      continue
    endif
    var source: dict<any> = {
      origin_tabnr: win.tabnr,
      origin_winid: win.winid,
      origin_bufnr: win.bufnr,
      status_tabnr: win.tabnr,
      status_winid: win.winid,
      status_bufnr: win.bufnr,
      repo_token: repo,
    }
    if !ValidStatusTarget(source, dir)
      continue
    endif
    var cursor_pos = getcurpos(win.winid)
    var refresh_ctx = StatusRefreshContext(source, dir,
      len(cursor_pos) > 1 ? cursor_pos[1] : 1)
    if !Dispatch({type: 'status', path: dir}, refresh_ctx)
      DebugLog('automatic status refresh could not reach daemon')
    endif
    seen[string(win.bufnr)] = true
  endfor
enddef

# A targeted mutation supersedes a pending refresh only for its own
# repository.  In particular, keep a global FocusGained/ShellCmdPost timer
# alive for other open repositories instead of swallowing their invalidation.
def ExcludePendingStatusRepo(repo: string)
  if s_status_refresh_timer == 0 || repo ==# ''
    return
  endif
  if s_status_refresh_repo_filter ==# repo
    # A repository-filtered timer has nothing left to do.
    CancelStatusRefresh()
  elseif s_status_refresh_repo_filter ==# ''
    s_status_refresh_excluded_repos[repo] = true
  endif
enddef

def RunScheduledStatusRefresh(force: bool, repo_filter: string, timer: number)
  # A stopped/replaced timer must not clear the replacement's state.
  if timer != s_status_refresh_timer
    return
  endif
  var excluded_repos = copy(s_status_refresh_excluded_repos)
  s_status_refresh_timer = 0
  s_status_refresh_forced = false
  s_status_refresh_repo_filter = ''
  s_status_refresh_excluded_repos = {}
  if force || (s_enabled && ConfBool('simplegit_status_auto_refresh', true))
    RefreshOpenStatus(repo_filter, excluded_repos)
  endif
enddef

def ScheduleStatusRefresh(force: bool = false, repo_filter: string = '')
  CancelStatusRefresh()
  if !force && (!s_enabled || !ConfBool('simplegit_status_auto_refresh', true))
    return
  endif
  if !has('timers')
    RefreshOpenStatus(repo_filter)
    return
  endif
  s_status_refresh_forced = force
  s_status_refresh_repo_filter = repo_filter
  s_status_refresh_excluded_repos = {}
  s_status_refresh_timer = timer_start(
    ConfNum('simplegit_status_refresh_delay', 150),
    (timer) => RunScheduledStatusRefresh(force, repo_filter, timer))
enddef

def HasOpenStatus(repo_filter: string = ''): bool
  for win in getwininfo()
    if bufname(win.bufnr) ==# STATUS_BUF
          && (repo_filter ==# ''
            || getbufvar(win.bufnr, 'simplegit_repo_token', '') ==# repo_filter)
      return true
    endif
  endfor
  return false
enddef

# Plugin mutations refresh their exact initiating status view immediately.
# Commands issued from a normal/commit buffer have no such target, but an
# independently open status view should still converge once, through the
# debounced same-repository path.
def RefreshStatusAfterMutation(ctx: dict<any>, dir: string, lnum: number)
  if dir !=# '' && ValidStatusTarget(ctx, dir)
    var refresh_ctx = StatusRefreshContext(ctx, dir, lnum)
    if Dispatch({type: 'status', path: dir}, refresh_ctx)
      ExcludePendingStatusRepo(get(ctx, 'repo_token', RepoToken(dir)))
    endif
  else
    var repo = dir ==# '' ? '' : RepoToken(dir)
    if repo !=# '' && HasOpenStatus(repo)
      ScheduleStatusRefresh(true, repo)
    endif
  endif
enddef

def ValidStatusEntry(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'xy', v:null)) == v:t_string
        \ && type(get(entry, 'path', v:null)) == v:t_string
enddef

def OnStatus(ctx: dict<any>, ev: dict<any>)
  var entries = get(ev, 'entries', v:null)
  var branch = get(ev, 'branch', '')
  if type(entries) != v:t_list || type(branch) != v:t_string
    DebugLog('ignored malformed status response')
    return
  endif
  # A status view already carries everything the statusline API needs; feed
  # the cache from it so an open status window costs no extra branch reads.
  var ahead = get(ev, 'ahead', 0)
  var behind = get(ev, 'behind', 0)
  if branch !=# ''
    var repo = get(ctx, 'repo_token', '')
    RecordBranch(repo, branch,
      type(ahead) == v:t_number ? ahead : 0,
      type(behind) == v:t_number ? behind : 0)
    PublishRepo(repo)
  endif
  var dir = get(ctx, 'dir', getcwd())
  var root = get(ev, 'root', '')
  if type(root) != v:t_string
    root = ''
  endif
  var display = ['## ' .. (branch ==# '' ? '(no branch)' : branch)
    .. UpstreamSuffix(ahead, behind)]
  var paths: list<string> = ['']
  var requested_cursor_path = get(ctx, 'status_cursor_path', '')
  if type(requested_cursor_path) != v:t_string
    requested_cursor_path = ''
  endif
  var cursor_path_line = 0
  for entry in entries
    if !ValidStatusEntry(entry)
      continue
    endif
    var label = substitute(entry.xy, '\.', ' ', 'g')
    var line = label .. ' ' .. entry.path
    var orig = get(entry, 'orig', '')
    if type(orig) == v:t_string && orig !=# ''
      line ..= ' <- ' .. orig
    endif
    display->add(line)
    paths->add(entry.path)
    # Git reports a rename with the new path plus `orig`. Treat either as the
    # same logical row so a refresh following the rename keeps the user's
    # selection on that entry.
    if cursor_path_line == 0 && requested_cursor_path !=# ''
          && (entry.path ==# requested_cursor_path
            || (type(orig) == v:t_string && orig ==# requested_cursor_path))
      cursor_path_line = len(display)
    endif
  endfor
  if len(display) == 1
    display->add('   (working tree clean)')
    paths->add('')
  endif
  var height = min([max([len(display), 5]), 15])
  if get(ctx, 'refresh_only', false)
    if !ValidStatusTarget(ctx, dir)
      DebugLog('discarded stale status refresh for ' .. dir)
      return
    endif
    var target_bufnr = get(ctx, 'status_bufnr', 0)
    var old_count = len(getbufline(target_bufnr, 1, '$'))
    setbufvar(target_bufnr, '&modifiable', 1)
    setbufline(target_bufnr, 1, display)
    if old_count > len(display)
      deletebufline(target_bufnr, len(display) + 1, old_count)
    endif
    setbufvar(target_bufnr, 'simplegit_paths', paths)
    setbufvar(target_bufnr, 'simplegit_dir', dir)
    setbufvar(target_bufnr, 'simplegit_root', root)
    setbufvar(target_bufnr, 'simplegit_remote', IsRemotePath(dir))
    setbufvar(target_bufnr, 'simplegit_repo_token', RepoToken(dir))
    setbufvar(target_bufnr, '&modifiable', 0)
    var target_winid = get(ctx, 'status_winid', 0)
    win_execute(target_winid, 'setlocal nowrap nomodifiable')
    win_execute(target_winid, 'resize ' .. height)
    var target_line = cursor_path_line > 0 ? cursor_path_line
      : min([max([get(ctx, 'lnum', 1), 1]), len(display)])
    win_execute(target_winid, 'call cursor(' .. target_line .. ', 1)')
    return
  endif

  # :SimpleGitStatus is intentionally interactive, but its reply can arrive
  # after the user has moved on.  In that case opening/reusing a split would
  # yank focus back to the initiating tab, so discard the obsolete UI result.
  var request_key = get(ctx, 'status_request_key', '')
  var request_generation = get(ctx, 'status_request_generation', -1)
  if request_key ==# ''
        || get(s_status_latest, request_key, -2) != request_generation
    DebugLog('discarded superseded status reply')
    return
  endif
  remove(s_status_latest, request_key)
  if !OriginStillCurrent(ctx)
    DebugLog('discarded status reply after its origin changed')
    return
  endif

  # Initial and refresh-only requests compete on one buffer generation.  Do
  # this before OpenScratch(), which may clear or retire the old buffer.
  var existing_status = bufnr(STATUS_BUF)
  if existing_status > 0 && bufexists(existing_status)
    var reserved_bufnr = get(ctx, 'status_generation_bufnr', 0)
    var response_generation = get(ctx, 'status_generation', 0)
    if reserved_bufnr != existing_status || response_generation <= 0
          || getbufvar(existing_status, 'simplegit_status_generation', 0)
            != response_generation
      DebugLog('discarded stale initial status response for ' .. dir)
      return
    endif
  endif

  var target_bufnr = OpenScratch(STATUS_BUF, height)
  var landed_generation = get(ctx, 'status_generation', 0)
  if landed_generation > 0
    # Cross-tab replacement may have retired the buffer on which this
    # generation was reserved. Carry the reservation to its new target.
    setbufvar(target_bufnr, 'simplegit_status_generation', landed_generation)
  else
    NextStatusGeneration(target_bufnr)
  endif
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_paths = paths
  b:simplegit_dir = dir
  # The repository root the entries are relative to, as git on the daemon's
  # side reported it (empty from a daemon that predates the field).  A remote
  # status view can only open its entries through this: there is no local
  # git to ask.
  b:simplegit_root = root
  b:simplegit_remote = IsRemotePath(dir)
  b:simplegit_repo_token = RepoToken(dir)

  syntax match SimpleGitStatusBranch /^##.*/
  syntax match SimpleGitStatusUntracked /^??.*/
  syntax match SimpleGitStatusConflict /^u\S\+.*/

  nnoremap <silent><buffer> <CR> <ScriptCmd>StatusOpen(false)<CR>
  nnoremap <silent><buffer> d <ScriptCmd>StatusOpen(true)<CR>
  nnoremap <silent><buffer> a <ScriptCmd>StatusFileOp('add')<CR>
  nnoremap <silent><buffer> u <ScriptCmd>StatusFileOp('reset')<CR>
  nnoremap <silent><buffer> A <ScriptCmd>StatusAllOp('add_all')<CR>
  nnoremap <silent><buffer> U <ScriptCmd>StatusAllOp('reset_all')<CR>
  nnoremap <silent><buffer> R <ScriptCmd>StatusRefresh()<CR>
  nnoremap <silent><buffer> c <ScriptCmd>Commit(false)<CR>
  nnoremap <silent><buffer> C <ScriptCmd>Commit(true)<CR>
  var target_line = cursor_path_line > 0 ? cursor_path_line
    : min([max([get(ctx, 'lnum', 1), 1]), line('$')])
  execute ':' .. target_line
enddef

def StatusRefresh(lnum: number = 0)
  CancelStatusRefresh()
  var dir = get(b:, 'simplegit_dir', getcwd())
  var ctx = RequestContext('status', dir, lnum > 0 ? lnum : line('.'))
  if !has_key(ctx, 'status_winid')
    return
  endif
  ctx.refresh_only = true
  ctx.status_generation = NextStatusGeneration(ctx.status_bufnr)
  if !Dispatch({type: 'status', path: dir},
      ctx)
    Warn('daemon unavailable')
  endif
enddef

def StatusFileOp(op: string)
  var paths = get(b:, 'simplegit_paths', [])
  var dir = get(b:, 'simplegit_dir', getcwd())
  var lnum = line('.')
  if lnum > len(paths) || paths[lnum - 1] ==# ''
    return
  endif
  if !Dispatch({type: 'file_op', path: dir, op: op, file: paths[lnum - 1]},
      RequestContext('file_op', dir, lnum))
    Warn('daemon unavailable')
  endif
enddef

# Stage or unstage the entire repository represented by the status buffer.
# The placeholder file keeps this request readable by protocol-5 daemons; the
# daemon ignores it for the two repository-wide operation names.
def StatusAllOp(op: string)
  var dir = get(b:, 'simplegit_dir', getcwd())
  var ctx = RequestContext('file_op', dir, 1)
  ctx.requires_capability = CAP_REPOSITORY_FILE_OPS
  if !Dispatch({type: 'file_op', path: dir, op: op, file: '.'},
      ctx)
    Warn('daemon unavailable')
  endif
enddef

def RepositoryAllOp(op: string)
  var dir = CommitRepoDir()
  var ctx = RequestContext('file_op', dir, 1)
  ctx.requires_capability = CAP_REPOSITORY_FILE_OPS
  if !Dispatch({type: 'file_op', path: dir, op: op, file: '.'},
      ctx)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

export def StageAll()
  RepositoryAllOp('add_all')
enddef

export def UnstageAll()
  RepositoryAllOp('reset_all')
enddef

# =============================================================
# Commit
#
# The message is composed in a scratch buffer and sent over the daemon's stdin,
# so it may contain anything -- newlines, quotes, non-ASCII -- without shell
# quoting. Comment lines are stripped by `git commit --cleanup=strip`, matching
# what git's own editor flow does.
# =============================================================

# Which repository a commit belongs to.  The scratch windows this plugin opens
# (status, commit) have no file name, so expand('%:p:h') on them is not a
# directory and would silently fall through to getcwd() -- committing in
# whatever repository Vim happens to be started in rather than the one the
# status view is showing.  Those buffers record their own directory, so prefer
# it; :SimpleGitCommit bound to `c` in the status window depends on this.
def CommitRepoDir(): string
  var owned = get(b:, 'simplegit_dir', '')
  if type(owned) == v:t_string && owned !=# ''
        && (IsRemotePath(owned) || isdirectory(owned))
    return owned
  endif
  return CurrentBufferDir()
enddef

# The directory the current buffer's repository work is about: the remote
# directory of a remote buffer, the file's directory for a local one, and the
# working directory when the buffer has no file.
def CurrentBufferDir(): string
  var bufnr = bufnr('%')
  if BufIsRemote(bufnr)
    return PathDir(BufFilePath(bufnr))
  endif
  var dir = expand('%:p:h')
  if dir ==# '' || !isdirectory(dir)
    dir = getcwd()
  endif
  return dir
enddef

def CommitHelpLines(dir: string, amend: bool): list<string>
  var lines = [
    '',
    '# Write the commit message above, then :w to commit or :q to abort.',
    '#',
    '# Lines starting with # are ignored.',
  ]
  if amend
    lines->add('# This REWRITES the previous commit (git commit --amend).')
  endif
  lines->add('#')
  return lines
enddef

# Where a message the user still has to deal with is, so that the warning
# naming it is actionable from any tab.
def CommitBufWhere(bufnr: number): string
  for win in getwininfo()
    if win.bufnr == bufnr
      return win.tabnr == tabpagenr() ? 'in this tab' : printf('in tab %d', win.tabnr)
    endif
  endfor
  return 'elsewhere'
enddef

export def Commit(amend: bool = false)
  var existing = bufnr(COMMIT_BUF)
  if existing > 0 && bufexists(existing)
    if getbufvar(existing, 'simplegit_commit_pending', false)
      Warn('a commit is already in progress')
      return
    endif
    if getbufvar(existing, '&modified')
      # A message being written is not something to overwrite: opening on top
      # of it replaced its head with the help template and left its tail below,
      # and :w then committed those leftover lines as part of a different
      # commit.  Point at it instead and let the user finish or abort it.
      Warn('finish (:w) or abort (q) the commit message already open ' ..
        CommitBufWhere(existing))
      return
    endif
  endif
  var dir = CommitRepoDir()
  var request_ctx = RequestContext('commit', dir, 1)
  s_commit_generation += 1
  request_ctx.commit_generation = s_commit_generation
  if !StartDaemon()
    Warn('daemon unavailable; run ./install.sh')
    return
  endif

  OpenScratch(COMMIT_BUF, 12)
  setlocal buftype=acwrite modifiable
  setlocal filetype=gitcommit

  var body = CommitHelpLines(dir, amend)
  # Amending starts from the existing message so it can be edited rather than
  # retyped; it is fetched asynchronously and prepended when it arrives.
  setline(1, body)
  b:simplegit_dir = dir
  b:simplegit_remote = IsRemotePath(dir)
  b:simplegit_amend = amend
  b:simplegit_commit_generation = s_commit_generation
  b:simplegit_commit_pending = false
  b:simplegit_request_context = request_ctx
  normal! gg

  # :w commits. This is the muscle memory from git's own editor, and it keeps
  # the buffer from ever being written to disk.
  augroup SimpleGitCommitBuf
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> CommitFinish()
  augroup END
  nnoremap <silent><buffer> q <Cmd>call <SID>CommitAbort()<CR>

  if amend
    # Fetched asynchronously and prepended when it arrives, so amending edits
    # the existing message instead of silently replacing it.
    Dispatch({type: 'commit_message', path: dir},
      {kind: 'commit_message', interactive: false, dir: dir,
       repo_token: RepoToken(dir), commit_bufnr: bufnr('%'),
       commit_generation: s_commit_generation})
  endif
  startinsert
enddef

def CommitAbort()
  setlocal nomodified
  close
  echo '[SimpleGit] commit aborted'
enddef

def CommitFinish()
  if get(b:, 'simplegit_commit_pending', false)
    Warn('a commit is already in progress; wait for its result')
    return
  endif
  var dir = get(b:, 'simplegit_dir', getcwd())
  var amend = get(b:, 'simplegit_amend', false)
  var message: list<string> = []
  for line in getline(1, '$')
    if line !~# '^#'
      message->add(line)
    endif
  endfor
  var text = trim(join(message, "\n"))
  if text ==# ''
    # BufWriteCmd handlers must clear 'modified' themselves.  The message
    # remains visible for correction, but a handled empty :write must not
    # strand the scratch buffer in a permanently dirty state.
    setlocal nomodified
    Warn('empty commit message; nothing committed')
    return
  endif
  var stored = get(b:, 'simplegit_request_context', {})
  var ctx: dict<any> = type(stored) == v:t_dict ? extend({}, stored) : {}
  ctx.kind = 'commit'
  ctx.interactive = true
  ctx.dir = dir
  ctx.repo_token = get(ctx, 'repo_token', RepoToken(dir))
  ctx.commit_tabnr = tabpagenr()
  ctx.commit_winid = win_getid()
  ctx.commit_bufnr = bufnr('%')
  ctx.commit_changedtick = b:changedtick
  # Force a real boolean: the command passes <bang>0, which is a number, and
  # json_encode() would put 0 on the wire where the daemon expects false.
  if Dispatch({type: 'commit', path: dir, message: text, amend: amend ? true : false},
      ctx)
    b:simplegit_commit_pending = true
    setlocal nomodified
  else
    Warn('daemon unavailable')
  endif
enddef

def OnCommitMessage(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', [])
  if type(lines) != v:t_list || empty(lines)
    return
  endif
  # The buffer may have been closed, or the user may already have started
  # typing; in either case leave what is there alone.
  var bufnr = get(ctx, 'commit_bufnr', -1)
  if bufnr <= 0 || !bufexists(bufnr) || bufname(bufnr) !=# COMMIT_BUF
        || getbufvar(bufnr, 'simplegit_commit_generation', 0)
          != get(ctx, 'commit_generation', -1)
        || RepoToken(getbufvar(bufnr, 'simplegit_dir', ''))
          !=# get(ctx, 'repo_token', '')
    return
  endif
  var existing = getbufline(bufnr, 1, '$')
  var typed = filter(copy(existing), (_, l) => l !~# '^#' && trim(l) !=# '')
  if !empty(typed)
    return
  endif
  var body: list<string> = []
  for l in lines
    body->add(type(l) == v:t_string ? l : string(l))
  endfor
  setbufline(bufnr, 1, body + existing)
enddef

def OnCommit(ctx: dict<any>, ev: dict<any>)
  var sha = get(ev, 'sha', '')
  var subject = get(ev, 'subject', '')
  # Close the exact message buffer only once git has accepted the commit.  Use
  # win_execute() so a completion landing after a tab switch cannot drag the
  # user back to the commit window merely to close it.
  var commit_bufnr = get(ctx, 'commit_bufnr', -1)
  var message_changed = false
  if commit_bufnr > 0 && bufexists(commit_bufnr)
        && getbufvar(commit_bufnr, 'simplegit_commit_generation', 0)
          == get(ctx, 'commit_generation', -1)
    setbufvar(commit_bufnr, 'simplegit_commit_pending', false)
    message_changed = getbufvar(commit_bufnr, 'changedtick', -1)
      != get(ctx, 'commit_changedtick', -2)
  endif
  for win in getwininfo()
    if win.bufnr == commit_bufnr && bufname(win.bufnr) ==# COMMIT_BUF
          && getbufvar(commit_bufnr, 'simplegit_commit_generation', 0)
            == get(ctx, 'commit_generation', -1)
          && !message_changed
      setbufvar(commit_bufnr, '&modified', 0)
      try
        win_execute(win.winid, 'close')
      catch
        DebugLog('could not close completed commit buffer: ' .. v:exception)
      endtry
    endif
  endfor
  RefreshVisibleGitState()
  echo printf('[SimpleGit] committed %s %s%s', sha, subject,
    message_changed ? ' — newer message text kept open' : '')
  var dir = get(ctx, 'dir', '')
  RefreshStatusAfterMutation(ctx, dir, 1)
enddef

def OnFileOp(ctx: dict<any>, ev: dict<any>)
  # The index changed under every buffer of this repository; refresh what is
  # visible, then re-render only the exact status window it was triggered
  # from.  A top-level command issued in a normal buffer has no status target
  # and therefore never opens one as an asynchronous side effect.
  RefreshVisibleGitState()
  var dir = get(ctx, 'dir', '')
  RefreshStatusAfterMutation(ctx, dir, get(ctx, 'lnum', 1))
enddef

# The root the status entries are relative to.  The status reply carries it;
# only a daemon that predates the field leaves it empty, and then local git
# is asked -- which is fine for a local repository and impossible for a
# remote one.
def StatusRoot(dir: string): string
  var reported = get(b:, 'simplegit_root', '')
  if type(reported) == v:t_string && reported !=# ''
    return reported
  endif
  if IsRemotePath(dir)
    return ''
  endif
  var root = system('git -C ' .. shellescape(dir) .. ' rev-parse --show-toplevel')
  if v:shell_error != 0
    return dir
  endif
  return trim(root)
enddef

# The local file behind a remote path when the workspace is projected (sshfs,
# a bind mount, an explicit mapping), or '' in virtual mode.
def LocalPathFor(remote_path: string): string
  if !exists('*g:SimpleRemoteLocalPath')
    return ''
  endif
  var local = call('g:SimpleRemoteLocalPath', [remote_path])
  return type(local) == v:t_string ? local : ''
enddef

def StatusOpen(diff_it: bool)
  var paths = get(b:, 'simplegit_paths', [])
  var dir = get(b:, 'simplegit_dir', getcwd())
  var lnum = line('.')
  if lnum > len(paths) || paths[lnum - 1] ==# ''
    return
  endif
  var root = StatusRoot(dir)
  if root ==# ''
    Warn('the daemon did not report the repository root; rerun ./install.sh')
    return
  endif
  var full = JoinPath(root, paths[lnum - 1])
  if IsRemotePath(dir)
    # A projected workspace has a real file to edit; a virtual one opens the
    # remote:// buffer, which SimpleRemote fills.
    var local = LocalPathFor(full)
    full = local !=# '' ? local : REMOTE_PREFIX .. full
  endif
  close
  execute 'edit ' .. fnameescape(full)
  if diff_it
    Diff('')
  endif
enddef

export def Status()
  CancelStatusRefresh()
  if bufname('%') ==# STATUS_BUF
    StatusRefresh()
    return
  endif
  var dir = CurrentBufferDir()
  if !Dispatch({type: 'status', path: dir},
      InitialStatusContext(dir))
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Statusline API (public, stable)
#
# The gitsigns `b:gitsigns_status_dict` / FugitiveStatusline() equivalent: a
# buffer dict plus autoload accessors, so a statusline plugin can render
# `main +12 ~3 -1` without running its own git.  Statusline expressions are
# re-evaluated on every redraw, so every accessor here is O(cached hunks),
# never dispatches, never touches the filesystem and never blocks.  The branch
# is refreshed once per repository from the buffer lifecycle instead — see
# EnsureBranch() — and a buffer resolves its repository once, see
# BufRepoToken().
# =============================================================

# repo token -> {head: string, ahead: number, behind: number}
var s_branch_cache: dict<dict<any>> = {}
var s_branch_inflight: dict<bool> = {}
# Bumped whenever the cached branches stop being trustworthy (an external
# checkout, a daemon restart).  A read that was already on the wire when that
# happened answers the *old* question, so its reply carries the generation it
# was issued under and is dropped when it no longer matches -- otherwise the
# stale answer would refill the cache and EnsureBranch() would see a hit and
# never ask again.
var s_branch_generation: number = 0

# Forget cached branches -- one repository's, or every one -- and abandon the
# reads still in flight.
def InvalidateBranches(repo: string = '')
  s_branch_generation += 1
  if repo ==# ''
    s_branch_cache = {}
  elseif has_key(s_branch_cache, repo)
    remove(s_branch_cache, repo)
  endif
  # Dropping the in-flight marks (rather than keeping them until their replies
  # land) is what lets EnsureBranch() re-ask immediately; the abandoned replies
  # are recognised by their generation and discarded.  They are dropped for
  # every repository even when only one was invalidated: the generation is
  # global, so no reply that is already on the wire can be trusted any more.
  # The repositories that kept their cached value simply do not re-ask.
  s_branch_inflight = {}
enddef

def BranchReplyCurrent(ctx: dict<any>): bool
  return get(ctx, 'branch_generation', -1) == s_branch_generation
enddef

# bufnr -> {name, token}: which repository a buffer belongs to, remembered.
#
# Every accessor below starts here, and RepoToken() is not cheap: resolve() is
# one readlink per path component and the marker walk stats every ancestor
# directory, roughly 33 syscalls for a file a few directories deep.  Paid on
# every redraw -- which is what 'statusline' means -- that is a stall on any
# network filesystem, and it was paid even when the accessor went on to return
# an empty string.  A buffer does not change repository, so it is answered once.
var s_repo_token_cache: dict<dict<string>> = {}

def BufRepoToken(bufnr: number): string
  if bufnr <= 0 || !bufexists(bufnr) || !IsFileBuffer(bufnr)
    return ''
  endif
  # A wiped buffer number is handed out again, so the name the answer was
  # computed from is part of the key rather than something to invalidate on.
  var name = get(get(getbufinfo(bufnr), 0, {}), 'name', '')
  if name ==# ''
    return ''
  endif
  var key = string(bufnr)
  var remembered = get(s_repo_token_cache, key, {})
  if get(remembered, 'name', '') ==# name
    return remembered.token
  endif
  var path = BufFilePath(bufnr)
  if path ==# ''
    # Not on disk yet -- a new file, or one deleted underneath us.  Nothing to
    # remember: the answer may still change once it is written.
    return ''
  endif
  var token = RepoToken(PathDir(path))
  if len(s_repo_token_cache) >= 256 && !has_key(s_repo_token_cache, key)
    remove(s_repo_token_cache, keys(s_repo_token_cache)[0])
  endif
  s_repo_token_cache[key] = {name: name, token: token}
  return token
enddef

def RecordBranch(repo: string, head: string, ahead: number, behind: number)
  if repo ==# ''
    return
  endif
  if has_key(s_branch_inflight, repo)
    remove(s_branch_inflight, repo)
  endif
  # One entry per repository, so this stays small; the bound only guards a
  # session that visits an unreasonable number of worktrees.
  if len(s_branch_cache) >= 64 && !has_key(s_branch_cache, repo)
    remove(s_branch_cache, keys(s_branch_cache)[0])
  endif
  s_branch_cache[repo] = {head: head, ahead: ahead, behind: behind}
enddef

# Requesting a branch for a path outside any repository must not repeat on
# every BufEnter, so a failure is cached exactly like a success.
def RecordBranchFailure(repo: string)
  RecordBranch(repo, '', 0, 0)
enddef

# One background branch read per repository, issued from the buffer lifecycle.
# Never call this from a statusline expression: it dispatches.
def EnsureBranch(bufnr: number)
  if !s_enabled
    return
  endif
  var repo = BufRepoToken(bufnr)
  if repo ==# '' || has_key(s_branch_cache, repo) || has_key(s_branch_inflight, repo)
    return
  endif
  var dir = PathDir(BufFilePath(bufnr))
  # `dir` says the path *is* a directory: a remote request needs to name the
  # directory git runs in explicitly, the daemon cannot stat it to find out.
  var ctx: dict<any> = {kind: 'branch', interactive: false, repo_token: repo,
    dir: dir, branch_generation: s_branch_generation,
    requires_capability: CAP_BRANCH_SUMMARY}
  if Dispatch({type: 'branch', path: dir}, ctx)
    # Also set when the capability gate refused to send: an older daemon has
    # no branch data to give, and retrying on every buffer entry would only
    # repeat that verdict.  A restart clears this through ClearPending().
    s_branch_inflight[repo] = true
  endif
enddef

def OnBranch(ctx: dict<any>, ev: dict<any>)
  var head = get(ev, 'head', '')
  var ahead = get(ev, 'ahead', 0)
  var behind = get(ev, 'behind', 0)
  if type(head) != v:t_string || type(ahead) != v:t_number || type(behind) != v:t_number
    DebugLog('ignored malformed branch response')
    return
  endif
  if !BranchReplyCurrent(ctx)
    DebugLog('ignored superseded branch response')
    return
  endif
  var repo = get(ctx, 'repo_token', '')
  RecordBranch(repo, head, ahead, behind)
  PublishRepo(repo)
enddef

# =============================================================
# Repository watch
#
# `git checkout` in another terminal changes what every open buffer in that
# repository looks like, and Vim never hears about it: FocusGained only fires
# in a GUI or a terminal that reports focus, and ShellCmdPost only covers the
# commands Vim itself ran.  In a tmux pane next to a plain terminal Vim the
# signs simply stayed wrong.  So the daemon polls the git directory of each
# repository it is asked about and pushes an unsolicited repo_change; this side
# treats it exactly like a FocusGained scoped to that one repository.
# =============================================================

# repo token -> true once a watch has been asked for (the answer, success or
# capability refusal, is not re-asked; a daemon restart clears it).
var s_watch_requested: dict<bool> = {}
# Repository root as the daemon spells it -> our own repo token.  repo_change
# names the root, and only the ack can tie the two identities together.
var s_watch_roots: dict<string> = {}

def WatchEnabled(): bool
  return ConfBool('simplegit_watch', true)
enddef

# One watch per repository, registered from the buffer lifecycle beside the
# branch read.
def EnsureWatch(bufnr: number)
  if !s_enabled || !WatchEnabled()
    return
  endif
  var repo = BufRepoToken(bufnr)
  if repo ==# '' || has_key(s_watch_requested, repo)
    return
  endif
  var interval = ConfNum('simplegit_watch_interval', 2000)
  var dir = PathDir(BufFilePath(bufnr))
  var ctx: dict<any> = {kind: 'watch', interactive: false, repo_token: repo,
    dir: dir, requires_capability: CAP_REPO_WATCH}
  if Dispatch({type: 'watch', path: dir, interval_ms: interval}, ctx)
    # Set even when the capability gate refused: an older daemon cannot watch
    # anything, and asking again on every BufEnter would only repeat that.
    s_watch_requested[repo] = true
  endif
enddef

def OnWatch(ctx: dict<any>, ev: dict<any>)
  var root = get(ev, 'path', '')
  var repo = get(ctx, 'repo_token', '')
  if type(root) != v:t_string || root ==# '' || repo ==# ''
    DebugLog('ignored malformed watch response')
    return
  endif
  # A remote acknowledgement (no daemon sends one today: the watch is refused
  # for remote workspaces) is keyed under its namespace, so a repo_change
  # naming a bare root can only ever hit the local repository of that name.
  if IsRemotePath(repo)
    root = REMOTE_PREFIX .. root
  endif
  if len(s_watch_roots) >= 64 && !has_key(s_watch_roots, root)
    remove(s_watch_roots, keys(s_watch_roots)[0])
  endif
  s_watch_roots[root] = repo
enddef

def OnRepoChange(ev: dict<any>)
  if !s_enabled || !WatchEnabled()
    return
  endif
  var root = get(ev, 'path', '')
  if type(root) != v:t_string || !has_key(s_watch_roots, root)
    # A root we never registered, or one from before a restart: refreshing on
    # it would touch buffers we cannot attribute.
    DebugLog('ignored repo_change for an unknown repository')
    return
  endif
  var repo = s_watch_roots[root]
  if ConfBool('simplegit_status_auto_refresh', true) && HasOpenStatus(repo)
    ScheduleStatusRefresh(false, repo)
  endif
  RefreshVisibleGitState(repo)
enddef

def HunkCounts(bufnr: number): dict<number>
  var counts = {added: 0, changed: 0, removed: 0}
  for hunk in HunksFor(bufnr)
    if hunk.old_count == 0
      counts.added += hunk.new_count
    elseif hunk.new_count == 0
      counts.removed += hunk.old_count
    else
      counts.changed += hunk.new_count
    endif
  endfor
  return counts
enddef

def BuildStatusDict(bufnr: number): dict<any>
  var branch = get(s_branch_cache, BufRepoToken(bufnr), {})
  var counts = HunkCounts(bufnr)
  return {
    head: get(branch, 'head', ''),
    ahead: get(branch, 'ahead', 0),
    behind: get(branch, 'behind', 0),
    added: counts.added,
    changed: counts.changed,
    removed: counts.removed,
  }
enddef

def PublishStatusDict(bufnr: number)
  if bufnr <= 0 || !bufexists(bufnr)
    return
  endif
  var dict = BuildStatusDict(bufnr)
  var previous = getbufvar(bufnr, 'simplegit_status_dict', {})
  if type(previous) == v:t_dict && previous == dict
    return
  endif
  setbufvar(bufnr, 'simplegit_status_dict', dict)
  # Only pay for the event when somebody listens.  It carries no payload: a
  # consumer reads b:simplegit_status_dict of whatever window it redraws.
  if exists('#User#SimpleGitUpdate')
    silent doautocmd <nomodeline> User SimpleGitUpdate
  endif
enddef

# A branch answers for a repository, not for the one buffer that asked, so
# republish every visible file buffer sharing it.
def PublishRepo(repo: string)
  if repo ==# ''
    return
  endif
  for win in getwininfo()
    if IsFileBuffer(win.bufnr) && BufRepoToken(win.bufnr) ==# repo
      PublishStatusDict(win.bufnr)
    endif
  endfor
enddef

def TargetBuf(buf: number): number
  return buf > 0 && bufexists(buf) ? buf : bufnr('%')
enddef

# {head, ahead, behind, added, changed, removed} for one buffer. Every value is
# already known; an unknown branch is reported as an empty head, never as a
# missing key, so consumers never need to test for one.
export def StatusDict(buf: number = 0): dict<any>
  return BuildStatusDict(TargetBuf(buf))
enddef

# Branch name of this buffer's repository, the short sha when HEAD is
# detached, or '' while it is still unknown.
export def Head(buf: number = 0): string
  return get(s_branch_cache, BufRepoToken(TargetBuf(buf)), {})->get('head', '')
enddef

# Added/changed/removed *lines* in this buffer against the index, folded from
# the same hunks that drive the sign column.
export def HunkSummary(buf: number = 0): dict<number>
  return HunkCounts(TargetBuf(buf))
enddef

# The inline blame annotation for one line, rendered through
# g:simplegit_blame_format — '' while it is still unknown.  Like the other
# accessors this only reads caches and never dispatches, so a custom renderer
# can call it as freely as the plugin's own annotation does.
export def BlameAnnotation(buf: number = 0, lnum: number = 0): string
  var bufnr = TargetBuf(buf)
  var line_number = lnum > 0 ? lnum : (bufnr == bufnr('%') ? line('.') : 1)
  var blame = BlameFor(bufnr)
  if !empty(blame)
    return get(blame, 'failed', false) ? '' : LineAnnotation(blame, line_number)
  endif
  var cached = CachedLineBlame(bufnr, line_number)
  var sha: string = get(cached, 'sha', '')
  return sha ==# '' ? '' : FormatBlame(sha, cached)
enddef

# Ready-made segment, for example `main ↑2 +12 ~3 -1`. Empty while the branch
# is unknown or the buffer belongs to no repository, so a statusline can
# concatenate it unconditionally.
export def StatusLine(buf: number = 0): string
  var dict = BuildStatusDict(TargetBuf(buf))
  var head: string = get(dict, 'head', '')
  if head ==# ''
    return ''
  endif
  var parts = [head]
  for [key, marker] in [['ahead', '↑'], ['behind', '↓'],
      ['added', '+'], ['changed', '~'], ['removed', '-']]
    var count: number = get(dict, key, 0)
    if count > 0
      parts->add(marker .. count)
    endif
  endfor
  return join(parts, ' ')
enddef

# =============================================================
# SimpleRemote events
# =============================================================

# Forget the branches of every remote repository and abandon the reads in
# flight for them; local repositories keep theirs.
def InvalidateRemoteBranches()
  s_branch_generation += 1
  filter(s_branch_cache, (key, _) => !IsRemotePath(key))
  # Global generation, so no reply on the wire can be trusted any more; the
  # local repositories that kept their value simply do not re-ask.
  s_branch_inflight = {}
enddef

# Everything remembered about remote buffers and repositories.  A workspace
# came, went or moved: what was cached describes a host that may no longer be
# the one behind these paths, and the in-flight marks would otherwise keep a
# buffer from asking again once the new connection is ready.
def ForgetRemoteState()
  s_remote_warned = {}
  InvalidateRemoteBranches()
  # Tokens under the namespace of the workspace that is going away.
  filter(s_repo_token_cache, (_, entry) => !IsRemotePath(get(entry, 'token', '')))
  filter(s_watch_requested, (key, _) => !IsRemotePath(key))
  filter(s_watch_roots, (key, _) => !IsRemotePath(key))
  for info in getbufinfo()
    if !BufWorkspaceTied(info.bufnr)
      continue
    endif
    var key = string(info.bufnr)
    # A projected buffer keeps its name and its number across a disconnect
    # while its repository token flips between the workspace namespace and
    # the local path; the token cache is keyed by the name, so it cannot
    # notice that by itself.
    if has_key(s_repo_token_cache, key)
      remove(s_repo_token_cache, key)
    endif
    InvalidateBlame(info.bufnr)
    InvalidateHunks(info.bufnr)
    for store in [s_blame_inflight, s_hunk_inflight, s_hunk_stale]
      if has_key(store, key)
        remove(store, key)
      endif
    endfor
    filter(s_line_blame_inflight, (line_key, _) => line_key !~# '^' .. key .. ':')
  endfor
enddef

# User SimpleRemoteConnected / SimpleRemoteWorkspaceChanged /
# SimpleRemoteDisconnected: the workspace behind every remote:// path changed
# (a switch is Disconnected, Connecting, Connected in that order), or a
# projection appeared that turns local files into workspace files.  Drop what
# was cached for it and read the visible buffers again -- after a disconnect
# that read is refused quietly and remembered as such, after a connect it
# succeeds against the new host.
export def OnRemoteWorkspace()
  ForgetRemoteState()
  if !s_enabled
    return
  endif
  RefreshVisibleGitState()
enddef

# User SimpleRemoteBufferRead: a remote:// buffer was filled -- on open, after
# a reload, after a workspace switch.  BufReadPost does not fire for these
# buffers (their read is a BufReadCmd), and it is only now that b:vimrc_remote
# marks the buffer as remote, so this is the buffer's "you were (re)read".
export def OnRemoteBufferRead()
  if !s_enabled
    return
  endif
  var event = get(g:, 'simpleremote_event', {})
  var bufnr = type(event) == v:t_dict ? get(event, 'bufnr', -1) : -1
  if type(bufnr) != v:t_number || bufnr <= 0 || !bufexists(bufnr)
    return
  endif
  if bufnr == bufnr('%')
    RefreshHunks(true)
    ScheduleLineBlame()
    return
  endif
  # Filled while another window was current: refresh it in place if it is
  # showing; a hidden buffer is read when it is entered, as usual.
  InvalidateHunks(bufnr)
  InvalidateBlame(bufnr)
  if bufwinid(bufnr) == -1
    return
  endif
  EnsureBranch(bufnr)
  PublishStatusDict(bufnr)
  if SignsEnabled()
    RequestHunks(bufnr, 'signs', false)
  endif
enddef

# User SimpleRemoteFilesChanged: SimpleRemote created, changed or deleted
# workspace files outside a buffer write (its tree, an upload, an API write).
# The daemon's repository watch cannot see a remote git directory, so this is
# the remote counterpart of ShellCmdPost: re-read what is visible of the
# remote repositories and refresh their status views.  Which repository each
# change belongs to is not known here (a remote token is a directory, see
# RepoToken()), so every remote buffer is refreshed; the events are rare.
export def OnRemoteFilesChanged()
  if !s_enabled
    return
  endif
  var event = get(g:, 'simpleremote_event', {})
  var changes = type(event) == v:t_dict ? get(event, 'changes', []) : []
  if type(changes) == v:t_list && empty(changes)
    return
  endif
  InvalidateRemoteBranches()
  for win in getwininfo()
    if !BufIsRemote(win.bufnr)
      continue
    endif
    InvalidateBlame(win.bufnr)
    InvalidateHunks(win.bufnr)
    EnsureBranch(win.bufnr)
    RequestHunks(win.bufnr, 'signs', false)
  endfor
  ScheduleLineBlame()
  if ConfBool('simplegit_status_auto_refresh', true)
    RefreshOpenStatus('', {}, true)
  endif
enddef

# =============================================================
# Lifecycle
# =============================================================
export def Enable()
  if s_enabled
    return
  endif
  s_enabled = true
  s_line_blame_on = ConfBool('simplegit_line_blame', true)
  s_signs_on = ConfBool('simplegit_signs', true)
  # Manual enable is the escape hatch after repeated daemon failures.
  SetupCore()
  simplegit#core#ClearBreaker()
  StartDaemon()
  ScheduleLineBlame()
  RefreshHunks()
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false
  if s_blame_timer != 0
    timer_stop(s_blame_timer)
    s_blame_timer = 0
  endif
  if s_hunk_timer != 0
    timer_stop(s_hunk_timer)
    s_hunk_timer = 0
  endif
  ClearLineBlame(bufnr('%'))
  if has('signs')
    sign_unplace(SIGN_GROUP)
  endif
  Stop()
enddef

export def Stop()
  CancelStatusRefresh()
  SetupCore()
  simplegit#core#Stop()
  s_daemon_ready = false
  ClearPending()
  s_blame_cache = {}
  s_line_blame_cache = {}
  s_hunk_cache = {}
  InvalidateBranches()
enddef

export def Restart()
  CancelStatusRefresh()
  SetupCore()
  s_daemon_ready = false
  s_daemon_incompatible = false
  ClearPending()
  if simplegit#core#Restart()
    echom '[SimpleGit] daemon restarted'
  endif
enddef

export def ShowLog()
  simplegit#core#ShowLog()
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def Health()
  SetupCore()
  var h = simplegit#core#Health()
  echo '[SimpleGit] health'
  echo '  enabled:        ' .. (s_enabled ? 'yes' : 'no')
  echo '  daemon binary:  ' .. (h.exe_path ==# '' ? '(not found — run ./install.sh)' : h.exe_path)
  echo '  daemon running: ' .. (h.running ? 'yes' : 'no')
  echo '  daemon version: ' .. (s_daemon_version ==# '' ? 'unknown' : s_daemon_version)
        .. '/' .. s_daemon_protocol
        .. (s_daemon_incompatible ? ' (INCOMPATIBLE — rerun ./install.sh)' : '')
  echo '  whole-repo ops: '
        .. (!s_daemon_ready ? 'unknown (handshake pending)'
          : simplegit#core#HasCap(CAP_REPOSITORY_FILE_OPS) ? 'supported'
          : 'unavailable (rerun ./install.sh)')
  echo '  virtual text:   ' .. (VirtualTextSupported() ? 'supported' : 'unsupported (needs Vim 9.0.0067+)')
  echo '  popups:         ' .. (has('popupwin') ? 'supported' : 'unsupported')
  echo '  line blame:     ' .. (s_line_blame_on ? 'on' : 'off')
  echo '  hunk signs:     ' .. (SignsEnabled() ? 'on' : 'off')
  echo '  live diff:      up to ' .. ConfNum('simplegit_live_max_bytes', 1024 * 1024) .. ' bytes, '
        .. ConfNum('simplegit_hunk_delay', 300) .. 'ms debounce'
  echo '  status refresh: ' .. ConfNum('simplegit_status_refresh_delay', 150)
        .. 'ms debounce, '
        .. (ConfBool('simplegit_status_auto_refresh', true) ? 'on' : 'off')
        .. (s_status_refresh_timer != 0 ? ' (pending)' : '')
  echo '  per-line blame: '
        .. (!s_daemon_ready ? 'unknown (handshake pending)'
          : simplegit#core#HasCap(CAP_BLAME_LINE) ? 'supported'
          : 'unavailable (rerun ./install.sh)')
  echo '  branch summary: '
        .. (!s_daemon_ready ? 'unknown (handshake pending)'
          : simplegit#core#HasCap(CAP_BRANCH_SUMMARY) ? 'supported'
          : 'unavailable (rerun ./install.sh)')
  echo '  hunk ranges:    '
        .. (!s_daemon_ready ? 'unknown (handshake pending)'
          : simplegit#core#HasCap(CAP_HUNK_RANGE) ? 'supported'
          : 'unavailable (rerun ./install.sh)')
  echo '  repo watch:     '
        .. (!WatchEnabled() ? 'off (g:simplegit_watch)'
          : !s_daemon_ready ? 'unknown (handshake pending)'
          : !simplegit#core#HasCap(CAP_REPO_WATCH) ? 'unavailable (rerun ./install.sh)'
          : len(s_watch_roots) .. ' repositories, every '
            .. ConfNum('simplegit_watch_interval', 2000) .. 'ms')
  echo '  remote git:     ' .. RemoteHealth()
  echo '  cached buffers: ' .. len(s_blame_cache) .. ' blame, ' .. len(s_hunk_cache) .. ' hunks, '
        .. len(s_branch_cache) .. ' branches'
  echo '  pending:        ' .. len(s_pending)
  echo '  crashes:        ' .. h.crashes .. ' (restarts: ' .. h.restarts .. ')'
        .. (h.breaker_open ? ' — auto-restart disabled, run :SimpleGitRestart' : '')
  echo '  last message:   ' .. (s_last_error ==# '' ? '(none)' : s_last_error)
enddef

# One line for :SimpleGitHealth: whether a remote:// buffer would get its git
# from the workspace host right now, and if not, why.
def RemoteHealth(): string
  var mode = RemoteMode()
  if mode ==# 'never'
    return 'off (g:simplegit_remote_git = never)'
  endif
  if !s_daemon_ready
    return 'unknown (handshake pending)'
  endif
  var reason = RemoteUnavailable()
  if reason ==# '' && empty(RemoteExecArgv())
    reason = 'SimpleRemote has no argv-safe transport for this workspace'
  endif
  if reason !=# ''
    return 'unavailable (' .. reason .. ')'
  endif
  var workspace = get(g:, 'simpleremote_workspace', {})
  var count = 0
  for info in getbufinfo()
    if BufIsRemote(info.bufnr)
      count += 1
    endif
  endfor
  return printf('%s:%s via %s, %d remote buffer%s%s',
    get(workspace, 'kind', '?'), get(workspace, 'target', '?'),
    fnamemodify(get(RemoteExecArgv(), 0, ''), ':t'),
    count, count == 1 ? '' : 's',
    mode ==# 'always' ? ' (projected buffers too)' : '')
enddef

export def DebugStatus()
  Health()
enddef

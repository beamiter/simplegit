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

def BufFilePath(bufnr: number): string
  if !bufexists(bufnr) || getbufvar(bufnr, '&buftype') !=# ''
    return ''
  endif
  # getbufinfo names are absolute, unlike bufname(), which would resolve
  # relative to whatever the current directory happens to be by now.
  var name = get(get(getbufinfo(bufnr), 0, {}), 'name', '')
  return name !=# '' && filereadable(name) ? name : ''
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
  s_blame_inflight = {}
  s_line_blame_inflight = {}
  s_hunk_inflight = {}
  s_branch_inflight = {}
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
  var id = NextId()
  # Copy into a dict<any>: call sites pass all-string literals whose inferred
  # type would reject the numeric id.
  var wire: dict<any> = extend({}, req)
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
    s_hunk_cache[key] = {failed: true, hunks: []}
  elseif get(ctx, 'kind', '') ==# 'branch'
    RecordBranchFailure(get(ctx, 'repo_token', ''))
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
  s_blame_timer = timer_start(ConfNum('simplegit_blame_delay', 350), (_) => {
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
def RefreshVisibleGitState()
  if !s_enabled
    return
  endif
  # A commit, checkout or pull moves the branch as readily as the hunks.
  s_branch_cache = {}
  for win in getwininfo()
    if getbufvar(win.bufnr, '&buftype') !=# ''
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
  if !Dispatch({type: 'show', path: path, rev: sha},
      {kind: 'show', interactive: true, title: 'commit ' .. ShortSha(sha)})
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
def OpenScratch(name: string, height: number): number
  # Reuse an existing window for this name instead of stacking splits on
  # every invocation.
  for win in getwininfo()
    if bufname(win.bufnr) ==# name
      win_gotoid(win.winid)
      setlocal modifiable
      silent :%delete _
      if height > 0
        execute 'resize ' .. height
      endif
      return bufnr('%')
    endif
  endfor
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

def OpenStatusScratch(height: number): number
  # The status URI is intentionally stable, so only one such buffer can
  # exist. Reuse it inside the requesting tab, but never follow an old status
  # window into a different tab. If another tab owns it, retire that scratch
  # buffer in place and create the requested view beside the origin instead.
  var existing = bufnr(STATUS_BUF)
  if existing > 0 && bufexists(existing)
    for win in getwininfo()
      if win.bufnr == existing && win.tabnr == tabpagenr()
        win_gotoid(win.winid)
        setlocal modifiable
        silent :%delete _
        execute 'resize ' .. height
        return existing
      endif
    endfor
    silent execute 'bwipeout! ' .. existing
  endif
  return OpenScratch(STATUS_BUF, height)
enddef

def OnShow(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', v:null)
  if type(lines) != v:t_list
    DebugLog('ignored malformed show response')
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
  if !Dispatch({type: 'show', path: path, rev: use_rev},
      {kind: 'show', interactive: true, title: 'commit ' .. use_rev})
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
  if !Dispatch(req, {kind: 'show', interactive: true, title: 'commit ' .. ShortSha(sha)})
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
  if !Dispatch({type: 'log', path: path, limit: limit},
      {kind: 'log', interactive: true, path: path})
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
    win_gotoid(win)
    setlocal modifiable
    append(line('$'), display)
    setlocal nomodifiable
    b:simplegit_graph_shas = get(b:, 'simplegit_graph_shas', [])->extend(shas)
    b:simplegit_graph_skip = get(b:, 'simplegit_graph_skip', 0)
      + len(filter(copy(shas), (_, sha) => sha !=# ''))
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
  if !Dispatch({type: 'show', path: path, rev: sha},
      {kind: 'show', interactive: true, title: 'commit ' .. sha})
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
  if !Dispatch({type: 'graph_log', path: path, limit: limit, skip: 0},
      {kind: 'graph_log', interactive: true, path: path})
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
  if !Dispatch({type: 'cat', path: path, rev: use_rev},
      {kind: 'cat', interactive: true, bufnr: bufnr, rev: use_rev})
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

def HunkCovers(hunk: dict<any>, lnum: number): bool
  if hunk.new_count == 0
    return lnum == HunkLine(hunk)
  endif
  return lnum >= hunk.new_start && lnum < hunk.new_start + hunk.new_count
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
    # Answer in flight already; rerun once it lands so the last edit wins.
    s_hunk_stale[key] = true
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
  echo '[SimpleGit] ' .. (action ==# 'undo' ? 'hunk reverted' : 'hunk staged')
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

def ShowHunkPreview(bufnr: number)
  if bufnr != bufnr('%')
    return
  endif
  var lnum = line('.')
  for hunk in HunksFor(bufnr)
    if !HunkCovers(hunk, lnum)
      continue
    endif
    if has('popupwin')
      var winid = popup_atcursor(hunk.lines, {
        padding: [0, 1, 0, 1],
        border: [1, 1, 1, 1],
        borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        moved: 'any',
        maxheight: 20,
      })
      win_execute(winid, 'setlocal filetype=diff')
    else
      echo join(hunk.lines, "\n")
    endif
    return
  endfor
  Warn('no hunk under cursor')
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

export def HunkPreview()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'preview', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  ShowHunkPreview(bufnr)
enddef

def HunkOperate(op: string)
  var bufnr = HunkTarget(true)
  if bufnr < 0
    return
  endif
  var hunks = HunksFor(bufnr)
  if !empty(get(s_hunk_cache, string(bufnr), {})) && empty(hunks)
    Warn('no hunks in this buffer')
    return
  endif
  if !Dispatch({type: op, path: BufFilePath(bufnr), lnum: line('.')},
      {kind: 'hunk_op', bufnr: bufnr, interactive: true})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

export def HunkStage()
  HunkOperate('stage')
enddef

export def HunkUndo()
  HunkOperate('undo')
enddef

export def RefreshHunks()
  if !s_enabled
    return
  endif
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    return
  endif
  # The statusline API publishes a branch even where the sign column is off.
  EnsureBranch(bufnr)
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
  s_hunk_timer = timer_start(ConfNum('simplegit_hunk_delay', 300), (_) => {
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

def RefreshOpenStatus(repo_filter: string = '', excluded_repos: dict<bool> = {})
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
  # this before OpenStatusScratch(), which may clear or retire the old buffer.
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

  var target_bufnr = OpenStatusScratch(height)
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
  if type(owned) == v:t_string && owned !=# '' && isdirectory(owned)
    return owned
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

export def Commit(amend: bool = false)
  var existing = bufnr(COMMIT_BUF)
  if existing > 0 && bufexists(existing)
        && getbufvar(existing, 'simplegit_commit_pending', false)
    Warn('a commit is already in progress')
    return
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

def StatusRoot(dir: string): string
  # The daemon reports paths relative to the repository root.
  var root = system('git -C ' .. shellescape(dir) .. ' rev-parse --show-toplevel')
  if v:shell_error != 0
    return dir
  endif
  return trim(root)
enddef

def StatusOpen(diff_it: bool)
  var paths = get(b:, 'simplegit_paths', [])
  var dir = get(b:, 'simplegit_dir', getcwd())
  var lnum = line('.')
  if lnum > len(paths) || paths[lnum - 1] ==# ''
    return
  endif
  var full = StatusRoot(dir) .. '/' .. paths[lnum - 1]
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
  var dir = expand('%:p:h')
  if dir ==# '' || !isdirectory(dir)
    dir = getcwd()
  endif
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
# never dispatches and never blocks.  The branch is refreshed once per
# repository from the buffer lifecycle instead — see EnsureBranch().
# =============================================================

# repo token -> {head: string, ahead: number, behind: number}
var s_branch_cache: dict<dict<any>> = {}
var s_branch_inflight: dict<bool> = {}

def BufRepoToken(bufnr: number): string
  var path = BufFilePath(bufnr)
  return path ==# '' ? '' : RepoToken(fnamemodify(path, ':h'))
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
  var ctx: dict<any> = {kind: 'branch', interactive: false, repo_token: repo,
    requires_capability: CAP_BRANCH_SUMMARY}
  if Dispatch({type: 'branch', path: fnamemodify(BufFilePath(bufnr), ':h')}, ctx)
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
  var repo = get(ctx, 'repo_token', '')
  RecordBranch(repo, head, ahead, behind)
  PublishRepo(repo)
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
    if getbufvar(win.bufnr, '&buftype') ==# '' && BufRepoToken(win.bufnr) ==# repo
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
  s_branch_cache = {}
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
  echo '  cached buffers: ' .. len(s_blame_cache) .. ' blame, ' .. len(s_hunk_cache) .. ' hunks, '
        .. len(s_branch_cache) .. ' branches'
  echo '  pending:        ' .. len(s_pending)
  echo '  crashes:        ' .. h.crashes .. ' (restarts: ' .. h.restarts .. ')'
        .. (h.breaker_open ? ' — auto-restart disabled, run :SimpleGitRestart' : '')
  echo '  last message:   ' .. (s_last_error ==# '' ? '(none)' : s_last_error)
enddef

export def DebugStatus()
  Health()
enddef

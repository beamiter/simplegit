vim9script
# Remote workspaces (SimpleRemote): a remote:// buffer -- buftype acwrite,
# b:vimrc_remote, no local file -- gets blame, hunks, branch, status, history,
# diff, hunk operations and commits from the git of the workspace host.  Every
# request for it carries g:SimpleRemoteExecArgv() as `exec` and the remote
# directory as `cwd`; a local buffer carries neither.
#
# SimpleRemote itself is not on the runtimepath: its API is stubbed, its
# events are fired by hand with g:simpleremote_event set, exactly the way it
# fires them.  Driven by the protocol fixture, which echoes exec/cwd back and
# refuses a remote watch the way the real daemon does.

set nocompatible
set nomore
set hidden

var root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(root)
var fake = root .. '/tests/simplegit_fake_daemon.py'
if !executable(fake)
  setfperm(fake, 'rwxr-xr-x')
endif

var request_log = tempname()
$SIMPLEGIT_FAKE_LOG = request_log
$SIMPLEGIT_FAKE_OMIT_CAPABILITIES = ''
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary,blame_line,hunk_range,repo_watch,remote_exec'
$SIMPLEGIT_FAKE_HEAD = 'remote-main'
$SIMPLEGIT_FAKE_STATUS_ROOT = '/srv/app'
$SIMPLEGIT_FAKE_HUNKS = json_encode([
  {old_start: 1, old_count: 0, new_start: 2, new_count: 2, lines: ['@@ -1,0 +2,2 @@', '+two', '+three']},
])
g:simplegit_daemon_path = fake
g:simplegit_auto_enable = 0
# Short remote debounces so the suite does not wait on them.
g:simplegit_remote_blame_delay = 50
g:simplegit_remote_hunk_delay = 50
execute 'source ' .. fnameescape(root .. '/plugin/simplegit.vim')

def WaitFor(Cond: func(): bool, label: string, timeout_ms: number = 4000): bool
  for _ in range(timeout_ms / 10)
    if Cond()
      return true
    endif
    sleep 10m
  endfor
  assert_true(false, 'timeout: ' .. label)
  return false
enddef

def Requests(kind: string): list<dict<any>>
  var found: list<dict<any>> = []
  if !filereadable(request_log)
    return found
  endif
  for line in readfile(request_log)
    try
      var request = json_decode(line)
      if type(request) == v:t_dict && get(request, 'type', '') ==# kind
        found->add(request)
      endif
    catch
    endtry
  endfor
  return found
enddef

def Last(kind: string): dict<any>
  return get(Requests(kind), -1, {})
enddef

# Requests picked by the path they name rather than by their position in the
# log.  A file buffer issues two hunk reads -- BufReadPost and BufEnter -- and
# the second is deferred until the first reply lands, so it can be logged
# after the section that provoked it has already cleared the log.  Selecting
# by path (and, where two buffers spell the same path, by whether the request
# carries a transport) is what makes an assertion here about the request it
# means rather than about whichever request happened to arrive last.
def RequestsFor(kind: string, path: string): list<dict<any>>
  return filter(Requests(kind), (_, r) => get(r, 'path', '') ==# path)
enddef

def LastFor(kind: string, path: string): dict<any>
  return get(RequestsFor(kind, path), -1, {})
enddef

def RemoteFor(kind: string, path: string): list<dict<any>>
  return filter(RequestsFor(kind, path), (_, r) => !empty(get(r, 'exec', [])))
enddef

def LocalFor(kind: string, path: string): list<dict<any>>
  return filter(RequestsFor(kind, path), (_, r) => empty(get(r, 'exec', [])))
enddef

# Clear the log to start a section, once the traffic of the previous one has
# stopped: a straggling request logged after the delete belongs to the section
# that is over, and would otherwise be read as this section's first request.
def Reset(timeout_ms: number = 2000)
  var seen = -1
  var stable = 0
  for _ in range(timeout_ms / 25)
    var count = filereadable(request_log) ? len(readfile(request_log)) : 0
    if count == seen
      stable += 25
      if stable >= 150
        break
      endif
    else
      seen = count
      stable = 0
    endif
    sleep 25m
  endfor
  delete(request_log)
enddef

def ScratchBuf(name: string): number
  for info in getbufinfo()
    if info.name ==# name
      return info.bufnr
    endif
  endfor
  return -1
enddef

def Messages(): string
  return execute('messages')
enddef

# Only what SimpleGit said: `:edit` prints a line of its own on every buffer
# switch, which says nothing about whether the plugin spoke.
def GitSaid(): list<string>
  return filter(split(Messages(), "\n"), (_, line) => line =~# '^\[SimpleGit\]')
enddef

def CountMatches(text: string, pattern: string): number
  var count = 0
  var start = 0
  while true
    var found = match(text, pattern, start)
    if found < 0
      break
    endif
    count += 1
    start = found + 1
  endwhile
  return count
enddef

# --- The SimpleRemote stand-in ------------------------------------------------
const ARGV = ['/opt/simpleremote-daemon', 'exec', '--kind', 'ssh',
  '--target', 'devbox', '--root', '/srv/app', '--']
var g_argv: list<string> = copy(ARGV)
def g:SimpleRemoteExecArgv(): list<string>
  return copy(g_argv)
enddef
def g:SimpleRemoteLocalPath(remote_path: string): string
  var workspace = get(g:, 'simpleremote_workspace', {})
  var local_root: string = get(workspace, 'local_root', '')
  if local_root ==# '' || strpart(remote_path, 0, len('/srv/app')) !=# '/srv/app'
    return ''
  endif
  return local_root .. strpart(remote_path, len('/srv/app'))
enddef

def Workspace(extra: dict<any> = {}): dict<any>
  var snapshot: dict<any> = {
    id: 1, kind: 'ssh', target: 'devbox', root: '/srv/app', tree_root: '/srv/app',
    local_root: '', mode: 'virtual', runtime: '/opt/simpleremote-daemon',
    runtime_version: '0.9', protocol: 'json',
    probe: {git: '/usr/bin/git', runtime_ms: 40, status: 0},
    uri: 'remote:///srv/app',
  }
  return extend(snapshot, extra)
enddef

def Fire(event: string, payload: dict<any>)
  g:simpleremote_event = extend(copy(payload), {
    event: event,
    status: exists('g:simpleremote_workspace') ? 'ssh:devbox' : 'disconnected',
    time: localtime(),
  })
  execute 'doautocmd <nomodeline> User ' .. event
enddef

# A remote:// buffer the way SimpleRemote leaves one after the fill: named by
# its URI, acwrite, text in place, b:vimrc_remote set, then BufferRead fired.
def OpenRemote(path: string, lines: list<string>): number
  execute 'edit ' .. fnameescape('remote://' .. path)
  setlocal buftype=acwrite noswapfile
  setline(1, lines)
  setlocal nomodified
  b:vimrc_remote = {path: path, uri: 'remote://' .. path, generation: 1}
  Fire('SimpleRemoteBufferRead', {type: 'buffer-read', bufnr: bufnr('%'),
    path: path, workspace: get(g:, 'simpleremote_workspace', {})})
  return bufnr('%')
enddef

g:simpleremote_workspace = Workspace()

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(['one', 'two', 'three'], repo .. '/local.txt')

g:updates = 0
augroup SimpleGitRemoteTest
  autocmd!
  autocmd User SimpleGitUpdate g:updates += 1
augroup END

simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'daemon handshake')
assert_true(simplegit#core#HasCap('remote_exec'), 'the fixture advertises remote_exec')

# --- A local buffer carries no transport ------------------------------------
execute 'edit ' .. fnameescape(repo .. '/local.txt')
WaitFor(() => len(Requests('hunks')) >= 1 && len(Requests('branch')) >= 1,
  'a local buffer is read as before')
assert_false(has_key(Last('hunks'), 'exec'), 'local hunks carry no exec')
assert_false(has_key(Last('hunks'), 'cwd'), 'local hunks carry no cwd')
assert_false(has_key(Last('branch'), 'exec'), 'local branch carries no exec')
assert_equal(repo .. '/local.txt', get(Last('hunks'), 'path', ''))
WaitFor(() => simplegit#Head() ==# 'remote-main', 'the local branch is published')

# --- A remote:// buffer routes every request through the workspace ----------
Reset()
var remote_buf = OpenRemote('/srv/app/src/main.rs', ['fn main() {}', 'two', 'three'])
assert_equal('acwrite', &buftype)
WaitFor(() => !empty(RequestsFor('hunks', '/srv/app/src/main.rs')),
  'a remote buffer is read for hunks')
var hunks_req = LastFor('hunks', '/srv/app/src/main.rs')
assert_equal('/srv/app/src/main.rs', get(hunks_req, 'path', ''),
  'the plain remote path goes on the wire, not the URI')
assert_equal(ARGV, get(hunks_req, 'exec', []), 'hunks carry the exec prefix')
assert_equal('/srv/app/src', get(hunks_req, 'cwd', ''), 'hunks name the remote directory')
WaitFor(() => !empty(RequestsFor('branch', '/srv/app/src')),
  'a remote buffer asks for its branch')
var branch_req = LastFor('branch', '/srv/app/src')
assert_equal('/srv/app/src', get(branch_req, 'path', ''), 'branch names the directory')
assert_equal('/srv/app/src', get(branch_req, 'cwd', ''), 'branch cwd is that directory')
assert_equal(ARGV, get(branch_req, 'exec', []), 'branch carries the exec prefix')
WaitFor(() => !empty(RequestsFor('watch', '/srv/app/src')),
  'a remote buffer asks for a watch')
assert_equal(ARGV, get(LastFor('watch', '/srv/app/src'), 'exec', []),
  'watch carries the exec prefix')
sleep 100m
# The fixture refuses it the way the real daemon does; nothing breaks and the
# refusal is final for this repository.
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 200m
assert_equal(1, len(RequestsFor('watch', '/srv/app/src')),
  'a refused remote watch is not asked again')

# The statusline API works for the remote buffer as for a local one.
WaitFor(() => simplegit#Head(remote_buf) ==# 'remote-main', 'the remote branch is published')
WaitFor(() => get(getbufvar(remote_buf, 'simplegit_status_dict', {}), 'added', 0) == 2,
  'b:simplegit_status_dict counts the remote hunks')
assert_equal('remote-main +2', simplegit#StatusLine(remote_buf))
assert_true(g:updates > 0, 'User SimpleGitUpdate fired for the remote buffer')
assert_equal(2, len(sign_getplaced(remote_buf, {group: 'simplegit'})[0].signs),
  'signs are placed in the remote buffer')

# --- Live diff, line blame, history, diff, hunk operations, log ---------------
setline(2, 'two edited')
# TextChanged does not fire in a headless -es run; arm the debounce directly,
# the way tests/vim_integration.vim does.
simplegit#ScheduleHunks()
WaitFor(() => has_key(Last('hunks'), 'content'), 'the unsaved buffer is diffed live')
assert_equal(ARGV, get(Last('hunks'), 'exec', []), 'the live diff goes remote too')
setline(2, 'two')
setlocal nomodified

cursor(1, 1)
simplegit#BlameLine()
WaitFor(() => len(Requests('blame_line')) >= 1, 'line blame is requested')
assert_equal(ARGV, get(Last('blame_line'), 'exec', []), 'blame_line carries the prefix')
assert_equal('/srv/app/src', get(Last('blame_line'), 'cwd', ''))
assert_equal(1, get(Last('blame_line'), 'lnum', 0))
WaitFor(() => !empty(popup_list()), 'the blame popup opens for a remote line')
popup_clear()

simplegit#ToggleBlame()
WaitFor(() => len(Requests('blame')) >= 1, 'the sidebar blames the remote file')
assert_equal(ARGV, get(Last('blame'), 'exec', []), 'blame carries the prefix')
WaitFor(() => bufname('%') =~# '^simplegit://blame/', 'the sidebar opens')
assert_equal('simplegit://blame/main.rs', bufname('%'), 'the sidebar is named after the file')
simplegit#ToggleBlame()
WaitFor(() => bufnr('%') == remote_buf, 'the sidebar closes')

simplegit#History()
WaitFor(() => len(Requests('log')) >= 1, 'history is requested')
assert_equal('/srv/app/src/main.rs', get(Last('log'), 'path', ''))
assert_equal(ARGV, get(Last('log'), 'exec', []), 'log carries the prefix')
WaitFor(() => ScratchBuf('simplegit://history/main.rs') != -1, 'the history view opens')
WaitFor(() => bufname('%') ==# 'simplegit://history/main.rs', 'the history view is current')
execute "normal \<CR>"
WaitFor(() => len(Requests('show')) >= 1, 'a history entry shows the commit')
assert_equal('/srv/app/src/main.rs', get(Last('show'), 'file', ''),
  'the file restriction is the plain remote path')
assert_equal(ARGV, get(Last('show'), 'exec', []), 'show carries the prefix')
assert_equal('/srv/app/src', get(Last('show'), 'cwd', ''))
WaitFor(() => ScratchBuf('simplegit://commit deadbee') != -1, 'the commit view opens')
only!
execute 'buffer ' .. remote_buf

simplegit#Diff('')
WaitFor(() => len(Requests('cat')) >= 1, 'diff asks for the revision')
assert_equal(ARGV, get(Last('cat'), 'exec', []), 'cat carries the prefix')
assert_equal('HEAD', get(Last('cat'), 'rev', ''))
WaitFor(() => winnr('$') == 2, 'the diff split opens')
diffoff!
only!
execute 'buffer ' .. remote_buf

simplegit#Log()
WaitFor(() => len(Requests('graph_log')) >= 1, 'the graph log is requested')
assert_equal(ARGV, get(Last('graph_log'), 'exec', []), 'graph_log carries the prefix')
WaitFor(() => ScratchBuf('simplegit://log') != -1, 'the log view opens')
only!
execute 'buffer ' .. remote_buf

cursor(2, 1)
simplegit#HunkStage()
WaitFor(() => len(Requests('stage')) >= 1, 'a hunk is staged')
assert_equal(ARGV, get(Last('stage'), 'exec', []), 'stage carries the prefix')
assert_equal('/srv/app/src', get(Last('stage'), 'cwd', ''))
assert_equal(2, get(Last('stage'), 'lnum', 0))

# --- Status from a remote buffer, and opening an entry -----------------------
Reset()
simplegit#Status()
WaitFor(() => !empty(RequestsFor('status', '/srv/app/src')), 'status is requested')
assert_equal('/srv/app/src', get(LastFor('status', '/srv/app/src'), 'path', ''),
  'status names the remote directory')
assert_equal('/srv/app/src', get(LastFor('status', '/srv/app/src'), 'cwd', ''))
assert_equal(ARGV, get(LastFor('status', '/srv/app/src'), 'exec', []),
  'status carries the prefix')
WaitFor(() => bufname('%') ==# 'simplegit://status', 'the status view opens')
assert_equal('remote:///srv/app/src', get(b:, 'simplegit_dir', ''),
  'the status view remembers the remote directory')
assert_true(get(b:, 'simplegit_remote', false), 'and that it is remote')
assert_equal('/srv/app', get(b:, 'simplegit_root', ''), 'and the root the daemon reported')
assert_equal('remote:///srv/app/src/', get(b:, 'simplegit_repo_token', ''),
  'a remote token is namespaced')
# `a` stages the entry under the cursor through the workspace as well.
cursor(2, 1)
execute "normal a"
WaitFor(() => len(Requests('file_op')) >= 1, 'a status entry is staged')
assert_equal('add', get(Last('file_op'), 'op', ''))
assert_equal('sample.txt', get(Last('file_op'), 'file', ''), 'the entry stays repository-relative')
assert_equal('/srv/app/src', get(Last('file_op'), 'cwd', ''))
assert_equal(ARGV, get(Last('file_op'), 'exec', []), 'file_op carries the prefix')
WaitFor(() => len(RequestsFor('status', '/srv/app/src')) >= 2,
  'the view refreshes after the mutation')
# <CR> opens the entry as a remote:// buffer: there is no local git to ask
# for the root, the reply carried it.
cursor(2, 1)
execute "normal \<CR>"
WaitFor(() => bufname('%') ==# 'remote:///srv/app/sample.txt',
  'a status entry opens its remote:// path')
assert_equal('remote:///srv/app/sample.txt', bufname('%'))

# --- Commit from a remote buffer ---------------------------------------------
Reset()
execute 'buffer ' .. remote_buf
simplegit#Commit()
WaitFor(() => bufname('%') ==# 'simplegit://commit', 'the commit buffer opens')
assert_equal('remote:///srv/app/src', get(b:, 'simplegit_dir', ''),
  'the commit belongs to the remote directory')
assert_true(get(b:, 'simplegit_remote', false))
setline(1, 'remote subject')
write
WaitFor(() => len(Requests('commit')) >= 1, 'the commit is sent')
assert_equal('/srv/app/src', get(Last('commit'), 'path', ''))
assert_equal('/srv/app/src', get(Last('commit'), 'cwd', ''))
assert_equal(ARGV, get(Last('commit'), 'exec', []), 'commit carries the prefix')
assert_equal('remote subject', get(Last('commit'), 'message', ''))
WaitFor(() => ScratchBuf('simplegit://commit') == -1, 'the commit buffer closes on success')

# --- Two repositories that spell the same directory stay apart ---------------
# A remote checkout at the same absolute path as a local one shares nothing:
# the remote token is namespaced.
Reset()
mkdir(repo .. '/src', 'p')
writefile(['local main'], repo .. '/src/main.rs')
execute 'edit ' .. fnameescape(repo .. '/src/main.rs')
WaitFor(() => !empty(LocalFor('branch', repo .. '/src')),
  'the local file asks for its branch')
var twin = OpenRemote(repo .. '/src/main.rs', ['remote main'])
# The token is namespaced, so the remote twin cannot be answered out of the
# branch the local one just cached: it asks for itself, through the workspace.
WaitFor(() => !empty(RemoteFor('branch', repo .. '/src')),
  'the remote twin of that path asks for its own branch')
assert_equal(ARGV, get(get(RemoteFor('branch', repo .. '/src'), -1, {}), 'exec', []),
  'and asks it remotely')
execute 'bwipeout! ' .. twin

# --- SimpleRemote events -----------------------------------------------------
# A files-changed event is the remote counterpart of ShellCmdPost: visible
# remote buffers are re-read, local ones are left alone.
execute 'buffer ' .. remote_buf
only!
Reset()
Fire('SimpleRemoteFilesChanged', {changes: [{path: '/srv/app/src/other.rs', type: 'created'}],
  workspace: g:simpleremote_workspace})
WaitFor(() => !empty(RequestsFor('hunks', '/srv/app/src/main.rs'))
    && !empty(RequestsFor('branch', '/srv/app/src')),
  'a files-changed event re-reads the remote buffer')
assert_equal('/srv/app/src/main.rs', get(Last('hunks'), 'path', ''))
assert_equal(0, len(filter(Requests('hunks'), (_, r) => !has_key(r, 'exec'))),
  'a files-changed event does not touch local buffers')

# A disconnect: the workspace is gone before the event fires, requests are
# refused quietly, nothing reaches the wire.
Reset()
unlet g:simpleremote_workspace
var before = Messages()
Fire('SimpleRemoteDisconnected', {reason: 'disconnect'})
sleep 300m
assert_equal(0, len(Requests('hunks')), 'nothing is sent for a remote buffer while disconnected')
assert_equal(0, CountMatches(strpart(Messages(), len(before)), 'no SimpleRemote workspace'),
  'a disconnect is not announced by SimpleGit')
# A command the user typed is answered all the same: the reason no refresh
# announces is still the reason this command did nothing, and a command that
# opens no view and says nothing is a keypress gone.
before = Messages()
simplegit#History()
sleep 200m
assert_equal(1, CountMatches(strpart(Messages(), len(before)), 'no SimpleRemote workspace is connected'),
  'an explicit command on a remote buffer is told why it did nothing')
assert_equal(-1, ScratchBuf('simplegit://history/main.rs'), 'and opens no history view')
assert_equal(0, len(Requests('log')), 'while nothing reached the wire')
# Reconnect: caches are dropped and the buffer is read again on the new host.
g:simpleremote_workspace = Workspace({id: 2})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
WaitFor(() => !empty(RequestsFor('hunks', '/srv/app/src/main.rs')),
  'a connect re-reads the visible remote buffer')
assert_equal(ARGV, get(LastFor('hunks', '/srv/app/src/main.rs'), 'exec', []))
WaitFor(() => !empty(RequestsFor('branch', '/srv/app/src')), 'and its branch')

# A BufferRead for a re-filled buffer is its BufReadPost.
Reset()
Fire('SimpleRemoteBufferRead', {type: 'buffer-read', bufnr: remote_buf,
  path: '/srv/app/src/main.rs', workspace: g:simpleremote_workspace})
WaitFor(() => !empty(RequestsFor('hunks', '/srv/app/src/main.rs')),
  'a re-read remote buffer is diffed again')

# The *first* request refused after a disconnect is the one that has to be
# answered too.  A status view is not a file buffer, so the disconnect leaves
# it un-refreshed: staging an entry from it reaches the refusal first, and a
# keypress that stages nothing, sends nothing and says nothing is a keypress
# gone.
Reset()
simplegit#Status()
WaitFor(() => bufname('%') ==# 'simplegit://status', 'the status view of the remote repository opens')
only!
sleep 200m
unlet g:simpleremote_workspace
Fire('SimpleRemoteDisconnected', {reason: 'disconnect'})
sleep 200m
Reset()
before = Messages()
cursor(2, 1)
execute "normal a"
sleep 200m
assert_equal(1, CountMatches(strpart(Messages(), len(before)), 'no SimpleRemote workspace is connected'),
  'the first request refused after a disconnect is answered, not swallowed')
assert_equal(0, len(Requests('file_op')), 'and nothing reached the wire')
execute "normal a"
sleep 200m
assert_equal(2, CountMatches(strpart(Messages(), len(before)), 'no SimpleRemote workspace is connected'),
  'and so is the next one')
g:simpleremote_workspace = Workspace({id: 2})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
sleep 200m
execute 'buffer ' .. remote_buf
only!

# --- Refusals: an old daemon, no git on the host, no transport, 'never' -------
# No remote_exec capability: nothing goes on the wire, said once.
Reset()
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary,blame_line,hunk_range,repo_watch'
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the old-daemon run')
var starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'old daemon handshake')
before = Messages()
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 300m
assert_equal(0, len(filter(Requests('hunks'), (_, r) => has_key(r, 'exec'))),
  'an old daemon is never sent a prefixed request')
assert_true(len(Requests('hunks')) >= 1, 'the local buffer is still served')
var said = strpart(Messages(), len(before))
assert_equal(1, CountMatches(said, 'remote git needs a newer daemon'),
  'the refusal is said once')
assert_match('remote git:     unavailable (remote git needs a newer daemon',
  execute('SimpleGitHealth'), 'health names the reason')
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 300m
assert_equal(1, CountMatches(strpart(Messages(), len(before)), 'remote git needs a newer daemon'),
  'and not again on the next buffer entry')

# A capable daemon but no git on the host, per the probe.
Reset()
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary,blame_line,hunk_range,repo_watch,remote_exec'
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the no-git run')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'capable daemon handshake')
before = Messages()
g:simpleremote_workspace = Workspace({id: 3, probe: {git: '', runtime_ms: 40, status: 0}})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 300m
assert_equal(0, len(filter(Requests('hunks'), (_, r) => has_key(r, 'exec'))),
  'a host without git is never asked')
assert_equal(1, CountMatches(strpart(Messages(), len(before)), 'git is not installed on the remote host'),
  'the missing git is said once')
assert_match('remote git:     unavailable (git is not installed', execute('SimpleGitHealth'))
# An interactive command still hears it.
simplegit#History()
sleep 100m
assert_equal(2, CountMatches(strpart(Messages(), len(before)), 'git is not installed on the remote host'),
  'an explicit command is told again')

# No argv-safe transport (plain ssh without the runtime).
g_argv = []
before = Messages()
g:simpleremote_workspace = Workspace({id: 4})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
Reset()
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 300m
assert_equal(0, len(filter(Requests('hunks'), (_, r) => has_key(r, 'exec'))),
  'without a transport nothing is sent')
assert_equal(1, CountMatches(strpart(Messages(), len(before)), 'no argv-safe transport'))
g_argv = copy(ARGV)

# 'never': a remote:// buffer has no git at all, and no complaint.
g:simplegit_remote_git = 'never'
g:simpleremote_workspace = Workspace({id: 5})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
Reset()
var quiet = GitSaid()
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. remote_buf
sleep 300m
assert_equal(0, len(filter(Requests('hunks'), (_, r) => has_key(r, 'exec'))),
  "'never' sends nothing for a remote buffer")
assert_equal('', simplegit#StatusLine(remote_buf), "'never' publishes nothing for it")
assert_match('remote git:     off (g:simplegit_remote_git = never)', execute('SimpleGitHealth'))
assert_equal(quiet, GitSaid(), "'never' says nothing")
g:simplegit_remote_git = 'auto'

# --- 'always': projected buffers use the workspace git too --------------------
# A projected workspace: local files under local_root, marked by SimpleRemote
# with b:simpleremote_path and the workspace id.
var mount = tempname()
mkdir(mount .. '/src', 'p')
writefile(['mounted'], mount .. '/src/lib.rs')
g:simpleremote_workspace = Workspace({id: 6, local_root: mount, mode: 'sshfs'})
Fire('SimpleRemoteConnected', {snapshot: g:simpleremote_workspace})
Reset()
execute 'edit ' .. fnameescape(mount .. '/src/lib.rs')
b:simpleremote_path = '/srv/app/src/lib.rs'
b:simpleremote_workspace_id = 6
# 'auto' (the default): local git over the mount, as before.
execute 'edit ' .. fnameescape(repo .. '/local.txt')
execute 'buffer ' .. bufnr(mount .. '/src/lib.rs')
WaitFor(() => !empty(RequestsFor('hunks', mount .. '/src/lib.rs')),
  "'auto' reads a projected buffer with local git")
assert_false(has_key(LastFor('hunks', mount .. '/src/lib.rs'), 'exec'),
  "'auto' sends no prefix for a projected buffer")

g:simplegit_remote_git = 'always'
Fire('SimpleRemoteWorkspaceChanged', {snapshot: g:simpleremote_workspace})
WaitFor(() => !empty(RequestsFor('hunks', '/srv/app/src/lib.rs')),
  "'always' reads a projected buffer through the workspace")
var projected = LastFor('hunks', '/srv/app/src/lib.rs')
assert_equal(ARGV, get(projected, 'exec', []), "'always' carries the prefix")
assert_equal('/srv/app/src', get(projected, 'cwd', ''), "'always' names the remote directory")
WaitFor(() => !empty(RemoteFor('branch', '/srv/app/src')),
  "'always' asks the branch remotely")
# The status view of a projected workspace opens entries as local files.
Reset()
simplegit#Status()
WaitFor(() => bufname('%') ==# 'simplegit://status', 'the projected status view opens')
assert_equal('remote:///srv/app/src', get(b:, 'simplegit_dir', ''))
cursor(2, 1)
execute "normal \<CR>"
WaitFor(() => bufname('%') ==# mount .. '/sample.txt',
  'a projected status entry opens the local file behind it')
# Once the workspace is gone the marker no longer means anything.
unlet g:simpleremote_workspace
Fire('SimpleRemoteDisconnected', {reason: 'disconnect'})
Reset()
execute 'edit ' .. fnameescape(mount .. '/src/lib.rs')
WaitFor(() => !empty(RequestsFor('hunks', mount .. '/src/lib.rs')),
  'a projected buffer is read after the disconnect')
assert_false(has_key(LastFor('hunks', mount .. '/src/lib.rs'), 'exec'),
  'and with local git: the marker outlived the workspace it belonged to')
g:simplegit_remote_git = 'auto'

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'remote daemon stops')
delete(repo, 'rf')
delete(mount, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/remote-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/remote-errors.log')
qall!

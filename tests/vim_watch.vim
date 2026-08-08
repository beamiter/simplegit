vim9script
# Repository watch: the daemon pushes a repo_change, and the plugin treats it
# as a FocusGained scoped to that one repository.
#
# Driven by the protocol fixture, which registers watches and can be told to
# emit an unsolicited event at a chosen moment -- the only way to test an
# event that answers no request.

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
var push_file = tempname()
$SIMPLEGIT_FAKE_LOG = request_log
$SIMPLEGIT_FAKE_PUSH_FILE = push_file
$SIMPLEGIT_FAKE_OMIT_CAPABILITIES = ''
# An older daemon first: repository file ops only, no watch.
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'
$SIMPLEGIT_FAKE_HEAD = 'watched'
$SIMPLEGIT_FAKE_HUNKS = json_encode([
  {old_start: 1, old_count: 1, new_start: 1, new_count: 1, lines: ['@@']},
])
g:simplegit_daemon_path = fake
g:simplegit_auto_enable = 0
g:simplegit_watch_interval = 250
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

# Renamed into place rather than written there: the fixture polls for the file
# and consumes it whole, so a reader that arrives mid-write would swallow the
# push.
def Push(event: dict<any>)
  var staging = push_file .. '.new'
  writefile([json_encode(event)], staging)
  rename(staging, push_file)
enddef

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(['one', 'two'], repo .. '/sample.txt')
writefile(['second'], repo .. '/second.txt')
var other = tempname()
mkdir(other .. '/.git', 'p')
writefile(['elsewhere'], other .. '/other.txt')

# --- Without the capability nothing reaches the wire -------------------------
simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'old daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
sleep 200m
assert_equal(0, len(Requests('watch')), 'an old daemon is never asked to watch')
assert_match('repo watch:     unavailable', execute('SimpleGitHealth'),
  'health names the missing capability')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'old daemon stops')

# --- A capable daemon is asked once per repository ---------------------------
delete(request_log)
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary,repo_watch'
var starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'capable daemon handshake')

execute 'edit ' .. fnameescape(repo .. '/sample.txt')
WaitFor(() => len(Requests('watch')) == 1, 'opening a buffer registers a watch')
assert_equal(repo, get(Requests('watch')[0], 'path', ''),
  'the watch names the buffer directory')
assert_equal(250, get(Requests('watch')[0], 'interval_ms', 0),
  'g:simplegit_watch_interval reaches the daemon')

execute 'edit ' .. fnameescape(repo .. '/second.txt')
sleep 200m
assert_equal(1, len(Requests('watch')), 'one watch serves the whole repository')
execute 'edit ' .. fnameescape(other .. '/other.txt')
WaitFor(() => len(Requests('watch')) == 2, 'a second repository is watched separately')

# --- A pushed change refreshes that repository, and only that one ------------
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
WaitFor(() => simplegit#Head() ==# 'watched', 'the branch is known before the push')
sleep 200m
var hunks_before = len(Requests('hunks'))
var branch_before = len(Requests('branch'))
# No FocusGained, no ShellCmdPost, no keypress: the daemon says so by itself.
Push({type: 'repo_change', id: 0, path: repo})
WaitFor(() => len(Requests('hunks')) > hunks_before,
  'a pushed change re-reads the hunks of the visible buffer')
WaitFor(() => len(Requests('branch')) > branch_before,
  'and re-reads the branch of that repository')

# --- A change in another repository leaves this buffer alone -----------------
sleep 300m
hunks_before = len(Requests('hunks'))
Push({type: 'repo_change', id: 0, path: other})
sleep 400m
assert_equal(hunks_before, len(Requests('hunks')),
  'a change in another repository does not re-read this buffer')

# --- An unknown root is ignored ---------------------------------------------
# A root that was never acknowledged cannot be attributed to any buffer, and a
# blanket refresh on it would be a request storm triggerable by one stray line.
hunks_before = len(Requests('hunks'))
Push({type: 'repo_change', id: 0, path: '/nowhere/at/all'})
sleep 400m
assert_equal(hunks_before, len(Requests('hunks')),
  'a repo_change for an unregistered root is ignored')

# --- A restart re-registers --------------------------------------------------
# The new daemon watches nothing; believing otherwise would leave the session
# permanently deaf to external changes.
var before_restart = len(Requests('watch'))
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the restart')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'restarted daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
WaitFor(() => len(Requests('watch')) > before_restart,
  'a restarted daemon is asked to watch again')

# --- g:simplegit_watch = 0 keeps it off --------------------------------------
delete(request_log)
g:simplegit_watch = 0
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the last restart')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'daemon handshake with watching off')
execute 'edit ' .. fnameescape(repo .. '/second.txt')
sleep 300m
assert_equal(0, len(Requests('watch')), 'watching off means nothing on the wire')
hunks_before = len(Requests('hunks'))
Push({type: 'repo_change', id: 0, path: repo})
sleep 400m
assert_equal(hunks_before, len(Requests('hunks')),
  'and a pushed change is ignored')
assert_match('repo watch:     off', execute('SimpleGitHealth'),
  'health says why')
g:simplegit_watch = 1

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'watch daemon stops')
delete(repo, 'rf')
delete(other, 'rf')
delete(request_log)
delete(push_file)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/watch-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/watch-errors.log')
qall!

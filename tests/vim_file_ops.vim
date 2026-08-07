vim9script
# Capability negotiation and asynchronous status-refresh regressions.  This
# uses a simplegit-specific protocol fixture; tests/fake_daemon.py is vendored
# simplecore test data and intentionally remains untouched.

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
$SIMPLEGIT_FAKE_OMIT_CAPABILITIES = '1'
$SIMPLEGIT_FAKE_FILE_OP_DELAY_MS = '0'
$SIMPLEGIT_FAKE_COMMIT_DELAY_MS = '0'
$SIMPLEGIT_FAKE_STATUS_DELAYS = ''
g:simplegit_daemon_path = fake
g:simplegit_auto_enable = 0
g:simplegit_status_refresh_delay = 80
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

def StatusBuf(): number
  return bufnr('simplegit://status')
enddef

def StatusHeader(bufnr: number): string
  return bufnr > 0 ? get(getbufline(bufnr, 1), 0, '') : ''
enddef

def ReplaceStatusHeader(bufnr: number, text: string)
  setbufvar(bufnr, '&modifiable', 1)
  setbufline(bufnr, 1, text)
  setbufvar(bufnr, '&modifiable', 0)
enddef

# An old protocol-5 daemon has no capability object.  Issue the command before
# its handshake completes to ensure Dispatch() gates the queued request at the
# wire boundary, rather than optimistically sending an unknown operation.
simplegit#StageAll()
WaitFor(() => simplegit#core#Ready(), 'old daemon handshake')
sleep 100m
assert_equal(0, len(Requests('file_op')), 'missing capability must fail closed')
assert_match('whole-repository stage/unstage requires a newer daemon', execute('messages'))
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'old daemon stops')

# A capable daemon accepts repository operations.  Delay the mutation reply so
# the user can change tabs before it arrives; only the captured status window
# may update, and current focus must remain untouched.
delete(request_log)
$SIMPLEGIT_FAKE_OMIT_CAPABILITIES = ''
$SIMPLEGIT_FAKE_FILE_OP_DELAY_MS = '250'
$SIMPLEGIT_FAKE_STATUS_DELAYS = '200'
var starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'capable daemon handshake')
assert_true(simplegit#core#HasCap('repository_file_ops'))

var fixture = tempname()
mkdir(fixture, 'p')
var sample = fixture .. '/sample.txt'
writefile(['sample'], sample)
execute 'edit ' .. fnameescape(sample)

# Even the initial interactive status reply is tied to its initiating view.
# Moving away before it lands must not pull focus back to open a split.
simplegit#Status()
WaitFor(() => len(Requests('status')) == 1, 'delayed initial status starts')
tabnew
var moved_winid = win_getid()
sleep 300m
assert_equal(-1, StatusBuf(), 'obsolete initial status does not open a split')
assert_equal(moved_winid, win_getid(), 'obsolete initial status preserves focus')
tabclose

simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-2', 'initial status')
var status_bufnr = StatusBuf()
var status_winid = win_getid()
var status_tabnr = tabpagenr()

execute 'normal A'
WaitFor(() => len(Requests('file_op')) == 1, 'repository operation reaches capable daemon')
# Insert a tab before the origin so its numeric tabnr changes while the stable
# winid remains live. Renumbering alone must not invalidate the target.
execute ':0tabnew'
var away_tabnr = tabpagenr()
var away_winid = win_getid()
var away_bufnr = bufnr('%')
WaitFor(() => StatusHeader(status_bufnr) ==# '## fake-3', 'origin status refresh')
assert_equal(away_tabnr, tabpagenr(), 'completion does not change the current tab')
assert_equal(away_winid, win_getid(), 'completion does not change the current window')
assert_equal(away_bufnr, bufnr('%'), 'completion does not change the current buffer')
assert_notequal(status_tabnr, get(getwininfo(status_winid), 0, {}).tabnr,
  'origin tab was renumbered during the request')

# Reusing the same status buffer for another repository invalidates the old
# operation's target even though its winid/bufnr still exist.
win_gotoid(status_winid)
execute 'normal A'
WaitFor(() => len(Requests('file_op')) == 2, 'repo-mismatch operation starts')
var other_repo = tempname()
mkdir(other_repo, 'p')
b:simplegit_dir = other_repo
b:simplegit_repo_token = fnamemodify(other_repo, ':p')
win_gotoid(away_winid)
sleep 500m
assert_equal(3, len(Requests('status')), 'reply cannot refresh a different repository')
assert_equal('## fake-3', StatusHeader(status_bufnr), 'different repository view is untouched')
setbufvar(status_bufnr, 'simplegit_dir', fixture)
setbufvar(status_bufnr, 'simplegit_repo_token', fnamemodify(fixture, ':p'))

# If the initiating status view disappears during the operation, its reply is
# silently dropped: no replacement split is opened in either tab.
win_gotoid(status_winid)
assert_equal(status_winid, win_getid())
execute 'normal A'
WaitFor(() => len(Requests('file_op')) == 3, 'second delayed operation starts')
close
win_gotoid(away_winid)
sleep 500m
assert_equal(-1, StatusBuf(), 'closed status view is not resurrected')
assert_equal(3, len(Requests('status')), 'closed target is not refreshed')
assert_equal(away_winid, win_getid(), 'dropped refresh preserves focus')

# A top-level command from a normal buffer carries no status target and must
# not manufacture one when its asynchronous reply arrives.
simplegit#StageAll()
WaitFor(() => len(Requests('file_op')) == 4, 'top-level operation is sent')
sleep 400m
assert_equal(-1, StatusBuf(), 'top-level operation does not open status')
assert_equal(3, len(Requests('status')), 'top-level operation does not request UI refresh')
assert_equal(away_winid, win_getid(), 'top-level completion preserves focus')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'focus-test daemon stops')

# Status reads themselves run concurrently.  Force the older refresh to land
# after the newer one: its generation token must prevent stale data from
# overwriting the final state.
delete(request_log)
$SIMPLEGIT_FAKE_FILE_OP_DELAY_MS = '0'
$SIMPLEGIT_FAKE_STATUS_DELAYS = '0,350,0'
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'generation-test daemon handshake')
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-1', 'generation initial status')
execute 'normal A'
execute 'normal U'
WaitFor(() => len(Requests('status')) == 3, 'both refreshes are dispatched')
sleep 500m
assert_equal('## fake-3', StatusHeader(StatusBuf()), 'late older refresh is discarded')

# An explicit status request in another tab must not follow the globally named
# scratch buffer back to the tab that used to display it. The old view is
# retired and the requested view opens beside its still-current origin.
var old_status_winid = win_getid()
tabnew
var new_status_tabnr = tabpagenr()
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-4', 'status opens in requesting tab')
assert_equal(new_status_tabnr, tabpagenr(), 'status never jumps to an old tab')
assert_notequal(old_status_winid, win_getid(), 'old cross-tab status window is not reused')

simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'generation-test daemon stops')

# Initial interactive status requests also use latest-wins generations. The
# older slow response must not open first and cause the newer response to be
# rejected merely because opening changed the current window.
delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = '350,0'
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'initial-generation daemon handshake')
tabnew
simplegit#Status()
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-2', 'newest initial status wins')
sleep 500m
assert_equal('## fake-2', StatusHeader(StatusBuf()), 'older initial status stays discarded')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'initial-generation daemon stops')

# Interactive opens and in-place automatic refreshes share one buffer
# generation. First let an older slow automatic read race with a newer fast
# explicit :SimpleGitStatus from the source window: the old automatic reply
# must not overwrite the explicit result.
var cross_status_bufnr = StatusBuf()
wincmd p
var cross_source_winid = win_getid()
delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = '350,0'
ReplaceStatusHeader(cross_status_bufnr, '## before-auto-explicit')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'auto-before-explicit daemon handshake')
simplegit#Enable()
simplegit#OnExternalChange()
WaitFor(() => len(Requests('status')) == 1, 'older automatic status starts')
simplegit#Status()
WaitFor(() => len(Requests('status')) == 2, 'newer explicit status starts')
WaitFor(() => StatusHeader(cross_status_bufnr) ==# '## fake-2',
  'newer explicit status lands')
sleep 450m
assert_equal('## fake-2', StatusHeader(cross_status_bufnr),
  'late automatic status cannot overwrite newer explicit status')

# Reverse the request order. A slow explicit open reserves the current status
# generation at dispatch; an automatic refresh requested afterwards advances
# it, so the late explicit reply neither overwrites the view nor steals focus.
wincmd p
assert_equal(cross_source_winid, win_getid(), 'cross-generation source window remains')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'auto-before-explicit daemon stops')
delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = '350,0'
ReplaceStatusHeader(cross_status_bufnr, '## before-explicit-auto')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'explicit-before-auto daemon handshake')
simplegit#Status()
WaitFor(() => len(Requests('status')) == 1, 'older explicit status starts')
simplegit#OnExternalChange()
WaitFor(() => len(Requests('status')) == 2, 'newer automatic status starts')
WaitFor(() => StatusHeader(cross_status_bufnr) ==# '## fake-2',
  'newer automatic status lands')
assert_equal(cross_source_winid, win_getid(), 'automatic reply keeps source focus')
sleep 450m
assert_equal('## fake-2', StatusHeader(cross_status_bufnr),
  'late explicit status cannot overwrite newer automatic status')
assert_equal(cross_source_winid, win_getid(), 'discarded explicit reply keeps source focus')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'cross-generation daemon stops')

# FocusGained/ShellCmdPost-style invalidations coalesce into one status read.
# The completion targets the existing view across tabs without changing the
# user's current focus. A targeted repository mutation refreshes immediately
# and excludes only that repository from the still-pending global timer.
delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = '0,0,0,0,0'
$SIMPLEGIT_FAKE_FILE_OP_DELAY_MS = '0'
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'automatic-status daemon handshake')
simplegit#Enable()
tabnew
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-1', 'automatic-status initial view')
var auto_status_bufnr = StatusBuf()
var auto_status_winid = win_getid()
cursor(2, 1)

# The explicit switch disables only Focus/Shell-driven status refresh; blame
# and hunk lifecycle stays enabled, and :SimpleGitStatus remains available.
g:simplegit_status_auto_refresh = 0
simplegit#OnExternalChange()
sleep 120m
assert_equal(1, len(Requests('status')), 'status auto-refresh can be disabled')
g:simplegit_status_auto_refresh = 1
simplegit#OnExternalChange()
simplegit#OnExternalChange()
tabnew
var auto_away_tabnr = tabpagenr()
var auto_away_winid = win_getid()
var auto_away_bufnr = bufnr('%')
WaitFor(() => len(Requests('status')) == 2, 'external-change burst coalesces')
WaitFor(() => StatusHeader(auto_status_bufnr) ==# '## fake-2',
  'existing status auto-refreshes')
assert_equal(auto_away_tabnr, tabpagenr(), 'auto-refresh keeps current tab')
assert_equal(auto_away_winid, win_getid(), 'auto-refresh keeps current window')
assert_equal(auto_away_bufnr, bufnr('%'), 'auto-refresh keeps current buffer')
assert_equal(2, getcurpos(auto_status_winid)[1], 'auto-refresh preserves target cursor line')

# A command issued from an ordinary buffer carries no status target. Its
# mutation reply still converges an independently open status exactly once via
# the debounced global path.
simplegit#StageAll()
WaitFor(() => len(Requests('file_op')) == 1, 'targetless repository mutation starts')
WaitFor(() => StatusHeader(auto_status_bufnr) ==# '## fake-3',
  'targetless mutation refreshes an open status')
sleep 200m
assert_equal(3, len(Requests('status')), 'targetless mutation refreshes once')

win_gotoid(auto_status_winid)
g:simplegit_status_refresh_delay = 250
simplegit#OnExternalChange()
execute 'normal A'
win_gotoid(auto_away_winid)
WaitFor(() => len(Requests('file_op')) == 2, 'targeted mutation starts during status debounce')
WaitFor(() => StatusHeader(auto_status_bufnr) ==# '## fake-4',
  'targeted mutation refreshes immediately')
assert_match('status refresh: .* (pending)', execute('SimpleGitHealth'),
  'global timer remains pending for other repositories')
sleep 350m
assert_equal(4, len(Requests('status')), 'pending timer excludes the refreshed repository')
g:simplegit_status_refresh_delay = 80

# Closing the only status target before the debounce expires must neither send
# a status request nor resurrect a scratch window.
win_gotoid(auto_status_winid)
simplegit#OnExternalChange()
close
win_gotoid(auto_away_winid)
sleep 200m
assert_equal(4, len(Requests('status')), 'closed status target is skipped before dispatch')
assert_equal(-1, StatusBuf(), 'automatic refresh never resurrects a closed status view')
assert_equal(auto_away_winid, win_getid(), 'closed-target debounce keeps focus')

# Disable is a hard boundary even if the scratch view remains after reopening:
# a later FocusGained-style callback cannot restart the daemon.
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-5', 'status reopens before disable')
var disabled_status_bufnr = StatusBuf()
simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'automatic-status daemon stops on disable')
simplegit#OnExternalChange()
sleep 200m
assert_equal(5, len(Requests('status')), 'disabled plugin ignores external status refresh')
assert_true(bufexists(disabled_status_bufnr), 'disable may leave the status scratch visible')
assert_false(simplegit#core#IsRunning(), 'external change after disable does not restart daemon')

# Repository identity follows the nearest .git marker rather than the request
# subdirectory. Open status through a symlink and mutate from a real-path
# sibling: the existing view must refresh exactly once. A distinct repository
# must not be mistaken for that view.
var shared_repo = tempname()
var shared_gitdir = tempname()
var shared_link = shared_repo .. '-link'
var distinct_repo = tempname()
mkdir(shared_repo .. '/a', 'p')
mkdir(shared_repo .. '/b', 'p')
mkdir(shared_gitdir, 'p')
writefile(['gitdir: ' .. shared_gitdir], shared_repo .. '/.git')
writefile(['a'], shared_repo .. '/a/a.txt')
writefile(['b'], shared_repo .. '/b/b.txt')
mkdir(distinct_repo .. '/b', 'p')
mkdir(distinct_repo .. '/.git', 'p')
writefile(['other'], distinct_repo .. '/b/other.txt')
system('ln -s ' .. shellescape(shared_repo) .. ' ' .. shellescape(shared_link))
assert_equal(0, v:shell_error, 'repository symlink fixture is created')

delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = '0,0'
$SIMPLEGIT_FAKE_FILE_OP_DELAY_MS = '0'
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'repository-token daemon handshake')
simplegit#Enable()
tabnew
execute 'edit ' .. fnameescape(shared_link .. '/a/a.txt')
simplegit#Status()
WaitFor(() => StatusHeader(StatusBuf()) ==# '## fake-1',
  'symlinked subdirectory status opens')
var repo_status_bufnr = StatusBuf()
wincmd p
execute 'edit ' .. fnameescape(shared_repo .. '/b/b.txt')
var sibling_source_winid = win_getid()
simplegit#StageAll()
WaitFor(() => len(Requests('file_op')) == 1, 'sibling repository mutation starts')
WaitFor(() => StatusHeader(repo_status_bufnr) ==# '## fake-2',
  'sibling repository mutation refreshes status')
sleep 200m
assert_equal(2, len(Requests('status')), 'sibling repository mutation refreshes once')
assert_equal(sibling_source_winid, win_getid(), 'sibling refresh keeps source focus')

execute 'edit ' .. fnameescape(distinct_repo .. '/b/other.txt')
var distinct_source_winid = win_getid()
simplegit#StageAll()
WaitFor(() => len(Requests('file_op')) == 2, 'distinct repository mutation starts')
sleep 200m
assert_equal(2, len(Requests('status')), 'distinct repository does not refresh status')
assert_equal('## fake-2', StatusHeader(repo_status_bufnr),
  'distinct repository leaves status contents untouched')
assert_equal(distinct_source_winid, win_getid(), 'distinct mutation keeps source focus')
simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'repository-token daemon stops')
delete(shared_link)
delete(shared_repo, 'rf')
delete(shared_gitdir, 'rf')
delete(distinct_repo, 'rf')

# Editing after :write must never be erased by the eventual commit success,
# and a second :write while that request is pending must not enqueue a second
# commit. The preserved buffer can be used for a deliberate follow-up commit.
delete(request_log)
$SIMPLEGIT_FAKE_STATUS_DELAYS = ''
$SIMPLEGIT_FAKE_COMMIT_DELAY_MS = '250'
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'commit-race daemon handshake')
tabnew
simplegit#Commit(false)
var commit_bufnr = bufnr('simplegit://commit')
assert_true(commit_bufnr > 0, 'commit message buffer opens')
setline(1, 'submitted message')
write
setline(1, 'newer message kept for later')
write
WaitFor(() => len(Requests('commit')) == 1, 'duplicate write is not dispatched')
tabnew
var commit_away_winid = win_getid()
WaitFor(() => !getbufvar(commit_bufnr, 'simplegit_commit_pending', true),
  'commit reply clears pending state')
assert_equal(commit_away_winid, win_getid(), 'commit reply keeps current focus')
assert_true(bufexists(commit_bufnr), 'edited message buffer remains open')
assert_equal('newer message kept for later', getbufline(commit_bufnr, 1)[0])
assert_true(getbufvar(commit_bufnr, '&modified'), 'post-write edits remain modified')
setbufvar(commit_bufnr, '&modified', 0)
execute 'bwipeout! ' .. commit_bufnr
simplegit#Stop()
delete(fixture, 'rf')
delete(other_repo, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/file-op-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/file-op-errors.log')
qall!

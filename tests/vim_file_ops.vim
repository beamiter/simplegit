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

vim9script
# Asynchronously opened views -- show, history, commit graph and diff -- are
# tied to the window that asked for them. Until this suite existed only the
# status/file_op/commit replies were guarded, so a slow :SimpleGitDiff or
# :SimpleGitShow could open a split in whatever window happened to be current
# when it landed, or follow a same-named scratch window into another tab.

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
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary,blame_line'
$SIMPLEGIT_FAKE_VIEW_DELAY_MS = '0'
$SIMPLEGIT_FAKE_SHOW_DELAYS = ''
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

def ScratchBuf(name: string): number
  for info in getbufinfo()
    if bufname(info.bufnr) ==# name
      return info.bufnr
    endif
  endfor
  return -1
enddef

def ScratchTab(name: string): number
  for win in getwininfo()
    if bufname(win.bufnr) ==# name
      return win.tabnr
    endif
  endfor
  return -1
enddef

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(['one', 'two', 'three'], repo .. '/first.txt')
writefile(['four', 'five', 'six'], repo .. '/second.txt')

simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/first.txt')

# --- A second :SimpleGitShow opens in the tab that asked for it -------------
# The scratch name is stable, and getwininfo() enumerates every tab page, so
# reusing "the window showing this name" used to drag the user to whichever
# tab opened it first.
simplegit#Show('HEAD')
WaitFor(() => ScratchBuf('simplegit://commit HEAD') != -1, 'show opens')
var first_tab = tabpagenr()
assert_equal(first_tab, ScratchTab('simplegit://commit HEAD'), 'show opens beside its origin')

tabnew
execute 'edit ' .. fnameescape(repo .. '/second.txt')
var second_tab = tabpagenr()
simplegit#Show('HEAD')
WaitFor(() => ScratchTab('simplegit://commit HEAD') == second_tab,
  'show opens in the requesting tab')
assert_equal(second_tab, tabpagenr(), 'show never switches the current tab')
assert_equal(1, len(filter(getwininfo(),
  (_, w) => bufname(w.bufnr) ==# 'simplegit://commit HEAD')),
  'the retired view is not left behind in the other tab')
tabclose
WaitFor(() => tabpagenr() == first_tab, 'back in the first tab')
execute 'silent! bwipeout! ' .. ScratchBuf('simplegit://commit HEAD')

# --- A late diff reply does not steal focus or open a split -----------------
delete(request_log)
$SIMPLEGIT_FAKE_VIEW_DELAY_MS = '300'
# Stop before restarting: core#Restart() on a live daemon hops through a timer
# that only re-Ensure()s once the old job is reaped, which a script driving it
# this tightly can outrun.
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the delayed run')
var starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'delayed daemon handshake')

only!
execute 'edit ' .. fnameescape(repo .. '/first.txt')
var diff_origin_winid = win_getid()
simplegit#Diff('HEAD')
WaitFor(() => len(Requests('cat')) == 1, 'diff request is sent')
tabnew
var away_winid = win_getid()
var away_bufnr = bufnr('%')
sleep 600m
assert_equal(away_winid, win_getid(), 'late diff reply keeps the current window')
assert_equal(away_bufnr, bufnr('%'), 'late diff reply keeps the current buffer')
assert_equal(1, winnr('$'), 'late diff reply opens no split here')
assert_equal(1, len(getwininfo(diff_origin_winid)), 'the origin window still exists')
assert_false(!!getwinvar(diff_origin_winid, '&diff'),
  'late diff reply does not put the origin window into diff mode')
tabclose

# The same command completes normally when the user stays put.
simplegit#Diff('HEAD')
WaitFor(() => winnr('$') == 2, 'diff split opens for a request nobody abandoned')
assert_true(!!getwinvar(diff_origin_winid, '&diff'), 'the origin window diffs')
diffoff!
only!

# --- A late show reply does not open a scratch window either ----------------
execute 'edit ' .. fnameescape(repo .. '/first.txt')
simplegit#Show('abandoned')
WaitFor(() => len(Requests('show')) >= 1, 'show request is sent')
tabnew
var show_away_winid = win_getid()
sleep 600m
assert_equal(-1, ScratchBuf('simplegit://commit abandoned'),
  'a show reply landing after its origin moved opens nothing')
assert_equal(show_away_winid, win_getid(), 'late show reply keeps focus')
tabclose
only!

# --- A late history reply does not open a window either ---------------------
execute 'edit ' .. fnameescape(repo .. '/first.txt')
simplegit#History()
WaitFor(() => len(Requests('log')) == 1, 'history request is sent')
tabnew
var log_away_winid = win_getid()
sleep 600m
assert_equal(-1, ScratchBuf('simplegit://history/first.txt'),
  'a history reply landing after its origin moved opens nothing')
assert_equal(log_away_winid, win_getid(), 'late history reply keeps focus')
tabclose
only!

# --- Two requests for one view are latest-wins ------------------------------
delete(request_log)
$SIMPLEGIT_FAKE_VIEW_DELAY_MS = '0'
$SIMPLEGIT_FAKE_SHOW_DELAYS = '350,0'
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'daemon stops before the latest-wins run')
starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'latest-wins daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/first.txt')
simplegit#Show('HEAD')
WaitFor(() => len(Requests('show')) == 1, 'the slow show is sent')
simplegit#Show('HEAD')
WaitFor(() => ScratchBuf('simplegit://commit HEAD') != -1, 'the fast show opens')
var show_bufnr = ScratchBuf('simplegit://commit HEAD')
assert_equal('commit fake-2', get(getbufline(show_bufnr, 1), 0, ''),
  'the newer reply wins')
sleep 450m
assert_equal('commit fake-2', get(getbufline(show_bufnr, 1), 0, ''),
  'the late older reply stays discarded')

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'views daemon stops')
delete(repo, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/views-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/views-errors.log')
qall!

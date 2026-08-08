vim9script
# Per-line blame: `git blame -L` instead of blaming the whole file to describe
# one line, the capability fallback to the whole-file request, the per-line
# cache, and g:simplegit_blame_format.
#
# The inline virtual-text annotation itself cannot be driven here: mode() is
# always 'c' under `vim -es`, and ShowLineBlameNow() deliberately renders only
# in normal mode. The request, cache and rendering layers it shares with the
# popup path are all exercised below.

set nocompatible
set nomore
set hidden

var root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(root)
var fake = root .. '/tests/simplegit_fake_daemon.py'
if !executable(fake)
  setfperm(fake, 'rwxr-xr-x')
endif

# Three days plus an hour, so the relative time cannot straddle a day boundary
# while the test runs.
var blame_time = localtime() - (3 * 86400 + 3600)
var request_log = tempname()
$SIMPLEGIT_FAKE_LOG = request_log
$SIMPLEGIT_FAKE_OMIT_CAPABILITIES = ''
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'
$SIMPLEGIT_FAKE_BLAME_TIME = string(blame_time)
$SIMPLEGIT_FAKE_BLAME_LINES = '10'
$SIMPLEGIT_FAKE_UNCOMMITTED_LNUM = '9'
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

def PopupLines(): list<string>
  var popups = popup_list()
  return empty(popups) ? [] : getbufline(winbufnr(popups[0]), 1, '$')
enddef

# Never index into a list a failed WaitFor may have left empty: an uncaught
# error aborts the script before qall!, and `vim -es` then blocks reading ex
# commands from stdin instead of reporting the failure.
def PopupLine(lnum: number): string
  return get(PopupLines(), lnum - 1, '')
enddef

def RequestLnum(kind: string, index: number): number
  return get(get(Requests(kind), index, {}), 'lnum', -1)
enddef

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(range(1, 10)->mapnew((_, n) => 'line ' .. n), repo .. '/sample.txt')

# --- Without the capability, one line still costs a whole-file blame --------
simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'old daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
cursor(2, 1)
simplegit#BlameLine()
WaitFor(() => !empty(PopupLines()), 'whole-file blame answers the popup')
assert_equal(0, len(Requests('blame_line')), 'no blame_line without the capability')
assert_equal(1, len(Requests('blame')), 'the old path blames the whole file')
assert_match('^Commit  deadbee', PopupLine(1), 'popup names the commit')
popup_clear()
simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'old daemon stops')

# --- With the capability, one line costs one `git blame -L` ------------------
delete(request_log)
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,blame_line'
simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'capable daemon handshake')
assert_true(simplegit#core#HasCap('blame_line'))

cursor(2, 1)
simplegit#BlameLine()
WaitFor(() => !empty(PopupLines()), 'per-line blame answers the popup')
assert_equal(1, len(Requests('blame_line')), 'exactly one line is blamed')
assert_equal(2, RequestLnum('blame_line', 0), 'the cursor line is the one blamed')
assert_equal(0, len(Requests('blame')),
  'annotating one line no longer blames the whole file')
assert_match('^Commit  deadbee', PopupLine(1), 'popup names the commit')
popup_clear()

# The same line again is answered from cache, without touching the daemon.
simplegit#BlameLine()
WaitFor(() => !empty(PopupLines()), 'cached line answers the popup')
sleep 100m
assert_equal(1, len(Requests('blame_line')), 'a cached line issues no request')
popup_clear()

# A different line is a separate, equally small request.
cursor(3, 1)
simplegit#BlameLine()
WaitFor(() => len(Requests('blame_line')) == 2, 'a second line is blamed on its own')
assert_equal(3, RequestLnum('blame_line', 1), 'the second request names line 3')
popup_clear()

# --- The annotation is rendered through g:simplegit_blame_format ------------
assert_equal('Alice, 3 days ago • initial import', simplegit#BlameAnnotation(),
  'the default format matches the previous hard-coded layout')
g:simplegit_blame_format = '%h %d %e: %s %% %z'
assert_equal(printf('deadbee %s alice@example.com: initial import %% %%z',
  strftime('%Y-%m-%d', blame_time)), simplegit#BlameAnnotation(),
  'every key expands, and an unknown key is left as typed')
# Rendering from the cached fields means a format change needs no refetch.
assert_equal(2, len(Requests('blame_line')), 'reformatting issues no request')
g:simplegit_blame_format = '%a, %w • %s'

# A line nobody has asked about yet has no annotation, and asking never
# dispatches: that is what makes the accessor safe on a redraw path.
assert_equal('', simplegit#BlameAnnotation(0, 7), 'an unknown line has no annotation')
sleep 100m
assert_equal(2, len(Requests('blame_line')), 'the accessor never dispatches')

# --- An uncommitted line is named, not blamed on a commit -------------------
cursor(9, 1)
simplegit#BlameLine()
WaitFor(() => len(Requests('blame_line')) == 3, 'the uncommitted line is blamed')
sleep 100m
assert_equal('Uncommitted changes', simplegit#BlameAnnotation(),
  'the zero sha renders as uncommitted')

# --- The whole-file cache still wins when the sidebar already paid for it ----
delete(request_log)
simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'per-line daemon stops')
simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'sidebar daemon handshake')
simplegit#ToggleBlame()
WaitFor(() => len(Requests('blame')) == 1, 'the sidebar blames the whole file')
WaitFor(() => bufname('%') =~# '^simplegit://blame/', 'the sidebar opens')
wincmd p
cursor(4, 1)
assert_equal('Alice, 3 days ago • initial import', simplegit#BlameAnnotation(),
  'the whole-file cache answers every line')
simplegit#BlameLine()
sleep 150m
assert_equal(0, len(Requests('blame_line')),
  'a cached whole-file blame is reused instead of asking per line')
popup_clear()

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'blame daemon stops')
delete(repo, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/blame-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/blame-errors.log')
qall!

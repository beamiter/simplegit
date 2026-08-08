vim9script
# Hunk navigation and preview requested while a refresh is already in flight.
# BufReadPost starts one for every file buffer, so this is the state a `]g`
# pressed straight after opening a file lands in: the keypress used to be
# swallowed with no jump and no message at all.

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
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'
# Long enough that the test is reliably inside the in-flight window.
$SIMPLEGIT_FAKE_HUNKS_DELAY_MS = '300'
# One added hunk at line 3, one changed hunk at line 6.
$SIMPLEGIT_FAKE_HUNKS = json_encode([
  {old_start: 2, old_count: 0, new_start: 3, new_count: 1,
   lines: ['@@ -2,0 +3 @@', '+added']},
  {old_start: 5, old_count: 1, new_start: 6, new_count: 1,
   lines: ['@@ -5 +6 @@', '-was', '+changed']},
])
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

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(range(1, 8)->mapnew((_, n) => 'line ' .. n), repo .. '/sample.txt')

simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'daemon handshake')

# --- ]g pressed while the BufReadPost refresh is still in flight ------------
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
WaitFor(() => len(Requests('hunks')) == 1, 'the buffer refresh is in flight')
cursor(1, 1)
simplegit#HunkNext()
assert_equal(1, line('.'), 'nothing can jump before the answer arrives')
WaitFor(() => line('.') == 3, 'the queued jump runs when the answer lands')

# Once the cache is warm the same key jumps straight away.
simplegit#HunkNext()
assert_equal(6, line('.'), 'a warm cache jumps immediately')
simplegit#HunkPrev()
assert_equal(3, line('.'), 'and back')

# --- [g and preview are queued the same way ---------------------------------
# BufReadPost and BufEnter both refresh, so the second of the two marked the
# buffer stale and a follow-up request is still on its way. Let it land before
# measuring, or it lands inside the next measurement instead.
sleep 700m
delete(request_log)
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 1, 'the write refresh is in flight')
cursor(8, 1)
simplegit#HunkPrev()
WaitFor(() => line('.') == 6, 'a queued backwards jump runs too')
sleep 200m
assert_equal(1, len(Requests('hunks')),
  'a queued jump reuses the in-flight answer instead of asking again')

delete(request_log)
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 1, 'the preview refresh is in flight')
cursor(3, 1)
simplegit#HunkPreview()
WaitFor(() => !empty(popup_list()), 'a queued preview opens its popup')
popup_clear()

# The later press wins, exactly as it would without the race.
delete(request_log)
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 1, 'the latest-press refresh is in flight')
cursor(1, 1)
simplegit#HunkPreview()
simplegit#HunkNext()
WaitFor(() => line('.') == 3, 'the last press decides what happens')
sleep 150m
assert_true(empty(popup_list()), 'the superseded preview does not also open')

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'hunks daemon stops')
delete(repo, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/hunks-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/hunks-errors.log')
qall!

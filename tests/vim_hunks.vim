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

def PlacedSigns(): list<dict<any>>
  return get(get(sign_getplaced(bufnr('%'), {group: 'simplegit'}), 0, {}),
    'signs', [])
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

# An invalidation clears actionable stale signs immediately.  If another
# invalidation happens while the refresh is in flight, its old reply must not
# repopulate the cache or repaint those signs before the follow-up lands.
delete(request_log)
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 1, 'first generation is in flight')
simplegit#OnBufWrite()
assert_true(empty(PlacedSigns()), 'an invalidation clears stale signs')
WaitFor(() => len(Requests('hunks')) == 2, 'stale reply starts current generation')
assert_true(empty(PlacedSigns()), 'a stale reply cannot repaint signs')
WaitFor(() => !empty(PlacedSigns()), 'the current generation restores signs')

# An interactive request can itself be the one invalidated.  With signs off,
# OnBufWrite has no background refresh to rescue it: the action must carry
# across the stale reply and run from a current-generation follow-up.
sleep 350m
delete(request_log)
g:simplegit_signs = 0
simplegit#OnBufWrite()
cursor(1, 1)
simplegit#HunkNext()
WaitFor(() => len(Requests('hunks')) == 1, 'interactive generation is in flight')
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 2, 'stale interactive request is retried')
WaitFor(() => line('.') == 3, 'the retried interactive action runs')
g:simplegit_signs = 1
simplegit#OnBufWrite()
sleep 350m

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

# --- A reply abandoned by a workspace switch cannot clear its successor ----
# Restart the fixture with per-request delays: A belongs to the old workspace,
# B to the new one.  A lands first.  If it clears B's in-flight slot, ]g sends
# an unnecessary C; with request ownership it queues onto B and B performs the
# jump when its current-generation answer arrives.
$SIMPLEGIT_FAKE_HUNKS_DELAYS = '0,250,900'
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,remote_exec'
def g:SimpleRemoteExecArgv(): list<string>
  return ['env']
enddef
g:simpleremote_workspace = {id: 1, kind: 'ssh', target: 'fixture', root: repo,
  probe: {git: 'git'}}
simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'old fixture stops before capability change')
simplegit#Enable()
WaitFor(() => simplegit#core#Ready() && simplegit#core#HasCap('remote_exec'),
  'fixture starts with remote capability')
WaitFor(() => !empty(PlacedSigns()), 'fixture warms the local hunk cache')
b:vimrc_remote = {path: repo .. '/sample.txt'}
delete(request_log)
simplegit#OnBufWrite()
WaitFor(() => len(Requests('hunks')) == 1, 'old workspace request is in flight')
g:simpleremote_workspace.id = 2
simplegit#OnRemoteWorkspace()
WaitFor(() => len(Requests('hunks')) == 2, 'new workspace request is in flight')
sleep 350m
cursor(1, 1)
simplegit#HunkNext()
sleep 50m
assert_equal(2, len(Requests('hunks')),
  'the old workspace reply cannot clear the new in-flight request')
WaitFor(() => line('.') == 3, 'the new workspace reply runs the queued jump')
unlet b:vimrc_remote
unlet g:simpleremote_workspace
delfunction g:SimpleRemoteExecArgv
$SIMPLEGIT_FAKE_HUNKS_DELAYS = ''
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'

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

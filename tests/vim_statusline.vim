vim9script
# The public statusline API: b:simplegit_status_dict, the User SimpleGitUpdate
# event and the simplegit#Head/HunkSummary/StatusDict/StatusLine accessors.
# Driven by the simplegit protocol fixture so branch and hunk data are exact.

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
# An older protocol-5 daemon: repository file ops only, no branch summary.
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'
$SIMPLEGIT_FAKE_HEAD = 'fake-branch'
$SIMPLEGIT_FAKE_AHEAD = '2'
$SIMPLEGIT_FAKE_BEHIND = '1'
# 3 added lines, 2 changed lines, 4 removed lines.
$SIMPLEGIT_FAKE_HUNKS = json_encode([
  {old_start: 1, old_count: 0, new_start: 2, new_count: 3, lines: ['@@']},
  {old_start: 8, old_count: 2, new_start: 10, new_count: 2, lines: ['@@']},
  {old_start: 20, old_count: 4, new_start: 21, new_count: 0, lines: ['@@']},
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

# Consumers redraw from this event; it must fire only when somebody listens,
# which is exactly what makes it safe to raise from a background reply.
g:updates = 0
augroup SimpleGitStatuslineTest
  autocmd!
  autocmd User SimpleGitUpdate g:updates += 1
augroup END

var repo = tempname()
mkdir(repo .. '/.git', 'p')
writefile(['one', 'two', 'three'], repo .. '/sample.txt')
var other_repo = tempname()
mkdir(other_repo .. '/.git', 'p')
writefile(['elsewhere'], other_repo .. '/other.txt')

# --- Without the capability the API is empty, and nothing reaches the wire ---
simplegit#Enable()
WaitFor(() => simplegit#core#Ready(), 'old daemon handshake')
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
sleep 150m
assert_false(simplegit#core#HasCap('branch_summary'), 'fixture withholds branch_summary')
assert_equal(0, len(Requests('branch')), 'missing capability keeps branch off the wire')
assert_equal('', simplegit#Head(), 'unknown branch reports an empty head')
assert_equal('', simplegit#StatusLine(), 'statusline segment is empty without a branch')
assert_match('branch summary: unavailable', execute('SimpleGitHealth'),
  'health names the missing capability')
simplegit#Stop()
WaitFor(() => !simplegit#core#IsRunning(), 'old daemon stops')

# --- A capable daemon publishes branch and per-buffer hunk counts ------------
delete(request_log)
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops,branch_summary'
var starts = simplegit#core#Health().starts
simplegit#Restart()
WaitFor(() => simplegit#core#Health().starts > starts && simplegit#core#Ready(),
  'capable daemon handshake')
assert_true(simplegit#core#HasCap('branch_summary'))

var sample_bufnr = bufnr('%')
simplegit#RefreshHunks()
WaitFor(() => simplegit#Head() ==# 'fake-branch', 'branch summary lands')
WaitFor(() => simplegit#HunkSummary().added == 3, 'hunk counts land')

assert_equal({added: 3, changed: 2, removed: 4}, simplegit#HunkSummary(),
  'hunk lines fold into added/changed/removed')
assert_equal({head: 'fake-branch', ahead: 2, behind: 1,
              added: 3, changed: 2, removed: 4},
  simplegit#StatusDict(), 'status dict carries branch and counts')
assert_equal('fake-branch ↑2 ↓1 +3 ~2 -4', simplegit#StatusLine(),
  'ready-made segment omits nothing that is non-zero')
assert_equal(simplegit#StatusDict(), b:simplegit_status_dict,
  'the buffer dict mirrors the accessor')
assert_true(g:updates > 0, 'User SimpleGitUpdate fires for listeners')

# The dict is per buffer: an explicit bufnr answers for that buffer even from
# somewhere else, and a buffer with no repository answers with zeroes.
enew
assert_equal({added: 3, changed: 2, removed: 4}, simplegit#HunkSummary(sample_bufnr),
  'an explicit bufnr answers for that buffer')
assert_equal('', simplegit#Head(), 'a buffer outside any repository has no head')
assert_equal({added: 0, changed: 0, removed: 0}, simplegit#HunkSummary(),
  'a buffer with no hunks answers with zeroes')

# --- The branch is read once per repository, never per buffer ---------------
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
writefile(['second'], repo .. '/second.txt')
execute 'edit ' .. fnameescape(repo .. '/second.txt')
sleep 200m
assert_equal(1, len(Requests('branch')), 'one branch read serves the whole repository')
assert_equal('fake-branch', simplegit#Head(), 'a sibling buffer reuses the cached branch')

execute 'edit ' .. fnameescape(other_repo .. '/other.txt')
WaitFor(() => len(Requests('branch')) == 2, 'a distinct repository is read separately')

# --- Statusline evaluation must never dispatch ------------------------------
# This runs on every redraw; one request per evaluation would be a request
# storm, and a synchronous read would stall the redraw itself.
sleep 200m
var before_branch = len(Requests('branch'))
var before_hunks = len(Requests('hunks'))
for _ in range(50)
  simplegit#StatusLine()
  simplegit#StatusDict()
  simplegit#Head()
  simplegit#HunkSummary()
endfor
sleep 200m
assert_equal(before_branch, len(Requests('branch')), 'accessors issue no branch requests')
assert_equal(before_hunks, len(Requests('hunks')), 'accessors issue no hunk requests')

# --- An external change re-reads the branch ---------------------------------
execute 'edit ' .. fnameescape(repo .. '/sample.txt')
var before_external = len(Requests('branch'))
simplegit#OnExternalChange()
WaitFor(() => len(Requests('branch')) > before_external,
  'a checkout-style external change re-reads the branch')
WaitFor(() => simplegit#Head() ==# 'fake-branch', 'the branch is republished')

# --- The accessors read caches, not the filesystem --------------------------
# 'statusline' re-evaluates these on every redraw, so "reads caches" has to
# cover the filesystem too: resolving which repository a buffer belongs to used
# to cost one readlink per path component plus a stat of every ancestor
# directory on every single call -- a stall on anything networked, and paid
# even when the answer was ''.  Proof by making the filesystem lie: with the
# marker moved away, a re-resolved token would name repo/sub and lose the
# branch, which is cached under the repository root.
mkdir(repo .. '/sub', 'p')
writefile(['deep'], repo .. '/sub/deep.txt')
execute 'edit ' .. fnameescape(repo .. '/sub/deep.txt')
WaitFor(() => simplegit#Head() ==# 'fake-branch', 'the branch answers for a nested file')
rename(repo .. '/.git', repo .. '/.git-moved')
assert_equal('fake-branch', simplegit#Head(),
  'a buffer resolves its repository once, not on every redraw')
assert_equal('fake-branch', get(simplegit#StatusDict(), 'head', ''),
  'the dict accessor reads the same remembered token')
assert_equal('fake-branch ↑2 ↓1', simplegit#StatusLine(),
  'and so does the ready-made segment')
rename(repo .. '/.git-moved', repo .. '/.git')

# --- The buffer dict is published where the sign column is off --------------
# b:simplegit_status_dict is documented on every file buffer, and consumers
# index it directly.  With g:simplegit_signs off no hunks are ever requested,
# so the hunk reply that used to be its only publisher never arrives, and every
# buffer after the first one carried no variable at all.
simplegit#ToggleSigns()
# Let the requests the previous sections issued with signs still on reach the
# log, so the count below is about this buffer and nothing else.
sleep 300m
var hunks_before = len(Requests('hunks'))
writefile(['fourth'], repo .. '/fourth.txt')
execute 'edit ' .. fnameescape(repo .. '/fourth.txt')
sleep 200m
assert_true(exists('b:simplegit_status_dict'),
  'a buffer opened with the sign column off still carries the dict')
assert_equal('fake-branch', get(b:simplegit_status_dict, 'head', ''),
  'and it carries the branch of its repository')
assert_equal(hunks_before, len(Requests('hunks')),
  'without the sign column nothing asks the daemon for hunks')
simplegit#ToggleSigns()

simplegit#Disable()
WaitFor(() => !simplegit#core#IsRunning(), 'statusline daemon stops')
delete(repo, 'rf')
delete(other_repo, 'rf')
delete(request_log)

if len(v:errors) > 0
  writefile(v:errors, root .. '/tests/statusline-errors.log')
  for error in v:errors
    echomsg error
  endfor
  cquit!
endif
delete(root .. '/tests/statusline-errors.log')
qall!

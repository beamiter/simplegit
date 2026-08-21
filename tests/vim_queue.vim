vim9script
# A bounded pre-handshake queue must fail closed.  Reporting a dropped request
# as accepted leaves its caller's in-flight token with no callback to release
# it, so even a later retry after the handshake is silently swallowed.

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
$SIMPLEGIT_FAKE_VERSION_DELAY_MS = '1500'
$SIMPLEGIT_FAKE_CAPS = 'repository_file_ops'
g:simplegit_daemon_path = fake
g:simplegit_auto_enable = 0
g:simplegit_line_blame = 0
g:simplegit_watch = 0
execute 'source ' .. fnameescape(root .. '/plugin/simplegit.vim')

def WaitFor(Condition: func(): bool, label: string, timeout_ms: number = 5000): bool
  for _ in range(timeout_ms / 10)
    if Condition()
      return true
    endif
    sleep 10m
  endfor
  assert_true(false, 'timeout: ' .. label)
  return false
enddef

def RequestsFor(path: string): list<dict<any>>
  var found: list<dict<any>> = []
  if !filereadable(request_log)
    return found
  endif
  for line in readfile(request_log)
    try
      var request = json_decode(line)
      if type(request) == v:t_dict && get(request, 'type', '') ==# 'hunks'
          && get(request, 'path', '') ==# path
        found->add(request)
      endif
    catch
    endtry
  endfor
  return found
enddef

var repo = tempname()
mkdir(repo .. '/.git', 'p')
for index in range(1, 40)
  writefile(['line ' .. index], printf('%s/file-%02d.txt', repo, index))
endfor

simplegit#Enable()
# One branch request plus the per-buffer hunk requests fills the queue.  The
# final buffer is deliberately beyond it and is current when the handshake
# eventually completes.
for index in range(1, 40)
  execute 'edit ' .. fnameescape(printf('%s/file-%02d.txt', repo, index))
endfor
var last_path = fnamemodify(bufname('%'), ':p')
WaitFor(() => simplegit#core#Ready(), 'delayed daemon handshake')
sleep 100m
assert_equal(0, len(RequestsFor(last_path)),
  'the overflow request unexpectedly reached the daemon')

simplegit#RefreshHunks()
WaitFor(() => len(RequestsFor(last_path)) == 1,
  'the dropped request can be retried after the handshake')

simplegit#Disable()
$SIMPLEGIT_FAKE_VERSION_DELAY_MS = ''
delete(repo, 'rf')
delete(request_log)
if !empty(v:errors)
  writefile(v:errors, root .. '/tests/queue-errors.log')
  cquit!
endif
delete(root .. '/tests/queue-errors.log')
qall!

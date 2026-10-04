vim9script
# Headless smoke test: the plugin and autoload scripts must load without
# errors and register their commands. Run with:
#   vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

set nocompatible
var root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(root)

var errors: list<string> = []

def Check(cond: bool, label: string)
  if !cond
    errors->add('FAIL: ' .. label)
  endif
enddef

# Loading must not throw.
try
  execute 'source ' .. fnameescape(root .. '/plugin/simplegit.vim')
catch
  errors->add('FAIL: plugin sourcing threw: ' .. v:exception)
endtry

Check(get(g:, 'loaded_simplegit', 0) == 1, 'g:loaded_simplegit is set')
Check(exists(':SimpleGitBlame') == 2, ':SimpleGitBlame exists')
Check(exists(':SimpleGitBlameLine') == 2, ':SimpleGitBlameLine exists')
Check(exists(':SimpleGitHistory') == 2, ':SimpleGitHistory exists')
Check(exists(':SimpleGitDiff') == 2, ':SimpleGitDiff exists')
Check(exists(':SimpleGitShow') == 2, ':SimpleGitShow exists')
Check(exists(':SimpleGitStatus') == 2, ':SimpleGitStatus exists')
Check(exists(':SimpleGitStageAll') == 2, ':SimpleGitStageAll exists')
Check(exists(':SimpleGitUnstageAll') == 2, ':SimpleGitUnstageAll exists')
Check(exists(':SimpleGitHealth') == 2, ':SimpleGitHealth exists')
Check(exists(':SimpleGitToggleLineBlame') == 2, ':SimpleGitToggleLineBlame exists')
Check(exists(':SimpleGitHunkNext') == 2, ':SimpleGitHunkNext exists')
Check(exists(':SimpleGitHunkPrev') == 2, ':SimpleGitHunkPrev exists')
Check(exists(':SimpleGitHunkPreview') == 2, ':SimpleGitHunkPreview exists')
Check(exists(':SimpleGitHunkStage') == 2, ':SimpleGitHunkStage exists')
Check(exists(':SimpleGitHunkUndo') == 2, ':SimpleGitHunkUndo exists')
Check(exists(':SimpleGitToggleSigns') == 2, ':SimpleGitToggleSigns exists')
Check(exists(':SimpleGitCommit') == 2, ':SimpleGitCommit exists')
Check(maparg('<Plug>(simplegit-blame)', 'n') !=# '', '<Plug>(simplegit-blame) mapped')
Check(maparg('<Plug>(simplegit-hunk-inner)', 'o') !=# '',
  '<Plug>(simplegit-hunk-inner) mapped in operator-pending mode')
Check(maparg('<Plug>(simplegit-hunk-stage)', 'x') !=# '',
  '<Plug>(simplegit-hunk-stage) mapped in visual mode')
Check(maparg('<Plug>(simplegit-hunk-stage)', 'n') !=# '', '<Plug>(simplegit-hunk-stage) mapped')
Check(maparg('<Plug>(simplegit-stage-all)', 'n') !=# '', '<Plug>(simplegit-stage-all) mapped')

# g:simplegit_version is the one version a user can read without a running
# daemon, and it is what they quote in a bug report -- so it has to be the
# version of this checkout, not whatever it said two releases ago.  Nothing
# else reads it, which is exactly why it drifted unnoticed.
var declared = ''
for line in readfile(root .. '/Cargo.toml')
  if line =~# '^version\s*='
    declared = matchstr(line, '"\zs[^"]*\ze"')
    break
  endif
endfor
Check(declared !=# '', 'Cargo.toml declares a version')
Check(get(g:, 'simplegit_version', '') ==# declared,
  'g:simplegit_version (' .. get(g:, 'simplegit_version', '') .. ') matches Cargo.toml ('
  .. declared .. ')')

# The autoload script must load and expose its entry points.
try
  simplegit#Health()
catch
  errors->add('FAIL: simplegit#Health threw: ' .. v:exception)
endtry

# The help promises Vim 9.1 with +job and +channel.  The guard is what keeps
# that promise, and it has to run before anything is registered: a plugin that
# defines its commands first fails later inside job_start with an E117 that
# names neither the build nor SimpleGit.
var plugin_lines = readfile(root .. '/plugin/simplegit.vim')
var guard = indexof(plugin_lines,
  (_, l) => l =~# "^if v:version < 901 .*!has('job').*!has('channel')")
var first_command = indexof(plugin_lines, (_, l) => l =~# '^command!')
Check(guard >= 0, 'plugin/simplegit.vim refuses Vim 9.0 and builds without +job/+channel')
Check(guard >= 0 && first_command > guard, 'the guard runs before any command is defined')
var guard_block = guard >= 0 ? join(plugin_lines[guard : guard + 5], "\n") : ''
Check(guard_block =~# "echomsg '\\[SimpleGit\\] Vim 9.1", 'the guard names the requirement')
Check(guard_block =~# '\n  finish\nendif', 'the guard finishes rather than falling through')

# A documented millisecond option set to 0 means "no debounce", not "unset":
# timer_start(0, ...) is valid Vim and fires on the next pass of the event
# loop.  The rejecting numeric reader substituted the documented default, and
# :SimpleGitHealth -- reading the same helper -- then confirmed that default,
# so a 0 read as never seen rather than as discarded.
var saved_hunk_delay = get(g:, 'simplegit_hunk_delay', 300)
var saved_status_delay = get(g:, 'simplegit_status_refresh_delay', 150)
g:simplegit_hunk_delay = 0
g:simplegit_status_refresh_delay = 0
var health = execute('SimpleGitHealth')
Check(health =~# 'live diff:\s\+up to \d\+ bytes, 0ms debounce',
  ':SimpleGitHealth honours g:simplegit_hunk_delay = 0')
Check(health =~# 'status refresh: 0ms debounce',
  ':SimpleGitHealth honours g:simplegit_status_refresh_delay = 0')
# A negative delay is still not a delay -- timer_start() would throw -- and a
# value of the wrong type still falls back to the documented default.
g:simplegit_hunk_delay = -5
g:simplegit_status_refresh_delay = 'soon'
health = execute('SimpleGitHealth')
Check(health =~# 'live diff:\s\+up to \d\+ bytes, 0ms debounce',
  'a negative g:simplegit_hunk_delay clamps to 0')
Check(health =~# 'status refresh: 150ms debounce',
  'a non-numeric delay falls back to its default')
g:simplegit_hunk_delay = saved_hunk_delay
g:simplegit_status_refresh_delay = saved_status_delay

# 0 is a real live-diff ceiling (disable), not "use the default megabyte".
var saved_live = get(g:, 'simplegit_live_max_bytes', 1024 * 1024)
g:simplegit_live_max_bytes = 0
health = execute('SimpleGitHealth')
Check(health =~# 'live diff:\s\+off (g:simplegit_live_max_bytes = 0)',
  ':SimpleGitHealth honours g:simplegit_live_max_bytes = 0')
g:simplegit_live_max_bytes = saved_live

# The daemon's 200ms floor used to be unreachable: ConfPositive(0) became 2000.
var saved_watch = get(g:, 'simplegit_watch_interval', 2000)
g:simplegit_watch_interval = 0
var sid = getscriptinfo({name: 'autoload/simplegit.vim'})[0].sid
var interval = call(function(printf('<SNR>%d_WatchIntervalMs', sid)), [])
Check(interval == 200, 'g:simplegit_watch_interval = 0 reaches the daemon floor (200ms)')
g:simplegit_watch_interval = saved_watch

g:simplegit_watch = 'off'
var watch_on = call(function(printf('<SNR>%d_WatchEnabled', sid)), [])
Check(!watch_on, 'g:simplegit_watch = ''off'' disables the repository watch')
unlet g:simplegit_watch

# Vim9 compiles def bodies lazily; force-compile every function by sourcing a
# copy of the autoload script with a trailing :defcompile.
var tmp = tempname() .. '.vim'
writefile(readfile(root .. '/autoload/simplegit.vim') + ['defcompile'], tmp)
try
  execute 'source ' .. fnameescape(tmp)
catch
  errors->add('FAIL: autoload defcompile: ' .. v:exception)
finally
  delete(tmp)
endtry

# Enable/disable lifecycle must not throw even without the daemon binary.
try
  g:simplegit_daemon_path = '/nonexistent/simplegit-daemon'
  simplegit#Enable()
  simplegit#Disable()
catch
  errors->add('FAIL: enable/disable lifecycle threw: ' .. v:exception)
endtry

if len(errors) > 0
  for line in errors
    verbose echomsg line
  endfor
  cquit!
endif
qall!

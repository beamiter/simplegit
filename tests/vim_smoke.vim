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

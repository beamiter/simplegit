vim9script

# Sourcing plugin/simplegit.vim a second time must leave it working.
#
# A plugin manager sources plugin/ again when the vimrc is reloaded.  The script
# is guarded, so nothing is redefined -- but plain `vim9script` deletes every
# script-local function and variable before the guard reaches `finish`, and the
# commands, autocommands and g: functions defined the first time round go on
# referring to them.
#
# Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_reload.vim

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
const SCRIPT = ROOT .. '/plugin/simplegit.vim'
const ERRORS = ROOT .. '/tests/plugin-reload-errors.log'
execute 'set runtimepath^=' .. fnameescape(ROOT)
delete(ERRORS)

def ScriptItems(): dict<list<string>>
  for info in getscriptinfo()
    if resolve(fnamemodify(info.name, ':p')) ==# SCRIPT
      var detail = getscriptinfo({sid: info.sid})[0]
      return {
        functions: sort(copy(detail.functions)),
        variables: sort(keys(detail.variables)),
      }
    endif
  endfor
  return {functions: [], variables: []}
enddef

g:simplegit_auto_enable = 0
execute 'source ' .. fnameescape(SCRIPT)
var before = ScriptItems()
assert_true(!empty(before.functions),
  'the script defines no script-local function: this test checks nothing')

execute 'source ' .. fnameescape(SCRIPT)
assert_equal(before, ScriptItems(),
  'sourcing the script again deleted script-local items')

if !empty(v:errors)
  writefile(v:errors, ERRORS)
  cquit
endif
qa!

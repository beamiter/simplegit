vim9script
# Headless integration test: drives the real daemon and verifies that every
# window-opening command actually opens its window. Requires a built daemon
# (./install.sh) and a git checkout with history; skips cleanly otherwise.
# Run with:
#   vim -Nu NONE -n -i NONE -es -S tests/vim_integration.vim

set nocompatible
var root = fnamemodify(expand('<sfile>:p:h'), ':h')
execute 'set runtimepath^=' .. fnameescape(root)

var daemon = root .. '/lib/simplegit-daemon'
if !executable(daemon)
  echomsg 'SKIP: lib/simplegit-daemon not built'
  qall!
endif
system('git -C ' .. shellescape(root) .. ' rev-parse --is-inside-work-tree')
if v:shell_error != 0
  echomsg 'SKIP: not a git checkout'
  qall!
endif

g:simplegit_daemon_path = daemon
g:simplegit_auto_enable = 0
execute 'source ' .. fnameescape(root .. '/plugin/simplegit.vim')

var errors: list<string> = []

def Check(cond: bool, label: string)
  if !cond
    errors->add('FAIL: ' .. label)
  endif
enddef

def WaitFor(Cond: func(): bool, label: string): bool
  for _ in range(100)
    if Cond()
      return true
    endif
    sleep 50m
  endfor
  errors->add('TIMEOUT: ' .. label)
  return false
enddef

def OtherWindowName(): string
  for win in getwininfo()
    var name = bufname(win.bufnr)
    if name =~# '^simplegit://'
      return name
    endif
  endfor
  return ''
enddef

def GotoSrc()
  var src_win = bufwinid(bufnr('README.md'))
  if src_win != -1
    win_gotoid(src_win)
  endif
  only!
enddef

execute 'edit ' .. fnameescape(root .. '/README.md')
simplegit#Enable()

# --- Blame sidebar -----------------------------------------------------------
simplegit#ToggleBlame()
if WaitFor(() => OtherWindowName() =~# '^simplegit://blame/', 'blame sidebar opens')
  var blame_buf = -1
  for win in getwininfo()
    if bufname(win.bufnr) =~# '^simplegit://blame/'
      blame_buf = win.bufnr
    endif
  endfor
  var src_lines = len(getbufline(bufnr('README.md'), 1, '$'))
  var blame_lines = len(getbufline(blame_buf, 1, '$'))
  Check(blame_lines == src_lines,
    'blame sidebar line count matches (' .. blame_lines .. ' vs ' .. src_lines .. ')')
  Check(get(getbufline(blame_buf, 1), 0, '') =~# '^\x\{7} ', 'blame line format')
endif
GotoSrc()

# --- File history ------------------------------------------------------------
simplegit#History()
if WaitFor(() => OtherWindowName() =~# '^simplegit://history/', 'history window opens')
  for win in getwininfo()
    if bufname(win.bufnr) =~# '^simplegit://history/'
      Check(get(getbufline(win.bufnr, 1), 0, '') =~# '^\x\{7} ', 'history line format')
    endif
  endfor
endif
GotoSrc()

# --- Repository status -------------------------------------------------------
simplegit#Status()
if WaitFor(() => OtherWindowName() ==# 'simplegit://status', 'status window opens')
  for win in getwininfo()
    if bufname(win.bufnr) ==# 'simplegit://status'
      Check(get(getbufline(win.bufnr, 1), 0, '') =~# '^## ', 'status branch header')
    endif
  endfor
endif
GotoSrc()

# --- Commit inspection -------------------------------------------------------
simplegit#Show('HEAD')
if WaitFor(() => OtherWindowName() =~# '^simplegit://commit', 'show window opens')
  for win in getwininfo()
    if bufname(win.bufnr) =~# '^simplegit://commit'
      Check(get(getbufline(win.bufnr, 1), 0, '') =~# '^commit ', 'show starts with commit line')
    endif
  endfor
endif
GotoSrc()

# --- Diff against HEAD -------------------------------------------------------
simplegit#Diff('')
if WaitFor(() => winnr('$') == 2, 'diff split opens')
  var src_win = bufwinid(bufnr('README.md'))
  Check(src_win != -1 && !!getwinvar(src_win, '&diff'), 'source window is in diff mode')
endif
diffoff!
GotoSrc()

simplegit#Disable()

if len(errors) > 0
  writefile(errors, '/dev/stderr')
  cquit!
endif
qall!

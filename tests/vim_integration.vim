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

# --- Hunks: signs, navigation, stage, undo ----------------------------------
# A throwaway repository keeps stage/undo away from this checkout.
var sandbox = tempname()
mkdir(sandbox, 'p')
def Git(dir: string, args: string): string
  var out = system('git -C ' .. shellescape(dir) .. ' ' .. args)
  if v:shell_error != 0
    errors->add('FAIL: git ' .. args .. ': ' .. out)
  endif
  return out
enddef
Git(sandbox, 'init -q')
Git(sandbox, 'config user.email test@example.com')
Git(sandbox, 'config user.name Test')
var sample = sandbox .. '/sample.txt'
writefile(['one', 'two', 'three', 'four', 'five', 'six'], sample)
Git(sandbox, 'add sample.txt')
Git(sandbox, 'commit -q -m initial')
writefile(['one', 'two changed', 'three', 'five', 'six', 'seven'], sample)

execute 'edit ' .. fnameescape(sample)

def PlacedSigns(): list<dict<any>>
  return get(get(sign_getplaced(bufnr('%'), {group: 'simplegit'}), 0, {}), 'signs', [])
enddef
def SignAt(lnum: number): string
  for sign in PlacedSigns()
    if sign.lnum == lnum
      return sign.name
    endif
  endfor
  return ''
enddef

if WaitFor(() => len(PlacedSigns()) > 0, 'hunk signs placed')
  Check(SignAt(2) ==# 'SimpleGitChange', 'change sign on line 2')
  Check(SignAt(3) ==# 'SimpleGitDelete', 'delete sign on line 3')
  Check(SignAt(6) ==# 'SimpleGitAdd', 'add sign on line 6')

  cursor(1, 1)
  simplegit#HunkNext()
  Check(line('.') == 2, 'HunkNext jumps to first hunk')
  simplegit#HunkNext()
  Check(line('.') == 3, 'HunkNext jumps to deletion anchor')
  simplegit#HunkNext()
  Check(line('.') == 6, 'HunkNext jumps to added line')
  simplegit#HunkPrev()
  Check(line('.') == 3, 'HunkPrev jumps back')

  cursor(2, 1)
  simplegit#HunkPreview()
  Check(len(popup_list()) > 0, 'hunk preview popup opens')
  popup_clear()

  cursor(6, 1)
  simplegit#HunkStage()
  WaitFor(() => Git(sandbox, 'diff --cached') =~# '+seven', 'hunk staged into index')
  WaitFor(() => SignAt(6) ==# '', 'stage refreshes signs')

  cursor(2, 1)
  simplegit#HunkUndo()
  WaitFor(() => getline(2) ==# 'two', 'hunk undo reverts buffer line')
  Check(readfile(sample)[1] ==# 'two', 'hunk undo reverts file on disk')

  # Live diff: signs must track unsaved buffer edits.
  setline(1, 'one live')
  simplegit#ScheduleHunks()
  WaitFor(() => SignAt(1) ==# 'SimpleGitChange', 'live diff marks unsaved edit')
  silent edit!

  # Status window: stage and unstage whole files in place.
  simplegit#Status()
  if WaitFor(() => OtherWindowName() ==# 'simplegit://status', 'status window opens')
    for win in getwininfo()
      if bufname(win.bufnr) ==# 'simplegit://status'
        win_gotoid(win.winid)
      endif
    endfor
    search('sample\.txt')
    execute 'normal a'
    WaitFor(() => Git(sandbox, 'diff') ==# '', 'status a stages the file')
    search('sample\.txt')
    execute 'normal u'
    WaitFor(() => Git(sandbox, 'diff --cached') ==# '', 'status u unstages the file')
    # A second :SimpleGitStatus reuses the window instead of stacking splits.
    simplegit#Status()
    sleep 200m
    var status_wins = 0
    for win in getwininfo()
      if bufname(win.bufnr) ==# 'simplegit://status'
        status_wins += 1
      endif
    endfor
    Check(status_wins == 1, 'status window is reused (' .. status_wins .. ')')
    close
  endif
endif

bwipeout!
delete(sandbox, 'rf')

simplegit#Disable()

if len(errors) > 0
  writefile(errors, '/dev/stderr')
  cquit!
endif
qall!

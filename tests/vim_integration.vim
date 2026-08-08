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
# Poll the watched repositories often enough for a test to observe a push.
g:simplegit_watch_interval = 200
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

# --- Statusline API against real git -----------------------------------------
# The fake-daemon suite pins the Vim-side contract; this pins that the daemon's
# branch summary agrees with git itself, including the detached-HEAD fallback
# a CI checkout routinely produces.
var expected_head = trim(system(
  'git -C ' .. shellescape(root) .. ' symbolic-ref --quiet --short HEAD'))
if v:shell_error != 0
  expected_head = trim(system('git -C ' .. shellescape(root) .. ' rev-parse --short HEAD'))
endif
if WaitFor(() => simplegit#Head() ==# expected_head, 'branch summary matches git')
  Check(simplegit#StatusLine() =~# '^' .. escape(expected_head, '\.*$^~[]'),
    'statusline segment starts with the branch')
  var dict = simplegit#StatusDict()
  Check(sort(keys(dict)) == ['added', 'ahead', 'behind', 'changed', 'head', 'removed'],
    'status dict has every documented key')
endif

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

# --- Repository commit graph --------------------------------------------------
def LogWinBuf(): number
  for win in getwininfo()
    if bufname(win.bufnr) ==# 'simplegit://log'
      return win.bufnr
    endif
  endfor
  return -1
enddef

simplegit#Log()
if WaitFor(() => LogWinBuf() != -1, 'log graph window opens')
  var log_buf = LogWinBuf()
  Check(get(getbufline(log_buf, 1), 0, '')
    =~# '^[ |/\\*_.-]*\x\{7,} \d\{4}-\d\{2}-\d\{2} ', 'log graph line format')
  var log_shas = getbufvar(log_buf, 'simplegit_graph_shas', [])
  Check(!empty(log_shas), 'log graph shas recorded')
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
  # ...and stop describing them once the edit is thrown away. A reload
  # replaces the text the cached hunks were computed from, so the answer has
  # to be asked for again rather than repainted.
  WaitFor(() => SignAt(1) ==# '', 'a reload drops the signs of the discarded edit')

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

    # Upper-case actions operate on the whole repository, not only the row or
    # the subdirectory from which the status view was opened.
    mkdir(sandbox .. '/nested', 'p')
    writefile(['top level'], sandbox .. '/bulk-top.txt')
    writefile(['nested'], sandbox .. '/nested/bulk-nested.txt')
    execute 'normal A'
    WaitFor(() => Git(sandbox, 'diff --cached --name-only') =~# 'bulk-top\.txt'
      && Git(sandbox, 'diff --cached --name-only') =~# 'nested/bulk-nested\.txt',
      'status A stages the whole repository')
    execute 'normal U'
    WaitFor(() => Git(sandbox, 'diff --cached') ==# '',
      'status U unstages the whole repository')
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

# --- Hunk ranges: stage and revert a selection ------------------------------
# A range collects every hunk it touches into ONE patch, so the ranges of the
# kept hunks have to be rebased against each other -- a deletion above an
# insertion shifts where that insertion lands on the index side.  The unit
# tests pin the arithmetic; only real `git apply` can say whether the patch it
# produces actually applies, which is what this section is for.
var range_repo = tempname()
mkdir(range_repo, 'p')
Git(range_repo, 'init -q')
Git(range_repo, 'config user.email test@example.com')
Git(range_repo, 'config user.name Test')
var committed = ['a1', 'a2', 'a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10']
var ranged = range_repo .. '/ranged.txt'
writefile(committed, ranged)
Git(range_repo, 'add ranged.txt')
Git(range_repo, 'commit -q -m initial')

# One change, one deletion and one insertion, in that order down the file:
#   1 a1  2 a2 changed  3 a3  4 a4  5 a6  6 a7  7 a8  8 NEW  9 a9  10 a10
var edited = ['a1', 'a2 changed', 'a3', 'a4', 'a6', 'a7', 'a8', 'NEW', 'a9', 'a10']
def ResetRanged()
  Git(range_repo, 'reset -q')
  Git(range_repo, 'checkout -q -- ranged.txt')
  writefile(edited, ranged)
  silent edit!
enddef

writefile(edited, ranged)
execute 'edit ' .. fnameescape(ranged)
if WaitFor(() => len(PlacedSigns()) > 0, 'range fixture signs placed')
  # A range covering only the insertion stages only the insertion.
  simplegit#HunkStage(8, 9)
  WaitFor(() => Git(range_repo, 'diff --cached') =~# '+NEW',
    'a narrow range stages its hunk')
  Check(Git(range_repo, 'diff --cached') !~# 'a2 changed',
    'a range does not stage a hunk it does not touch')
  Check(Git(range_repo, 'diff --cached') !~# '-a5',
    'a range does not stage the deletion above it')

  # The whole file in one go: three hunks, one patch, and the insertion has to
  # be rebased past the deletion that precedes it.
  ResetRanged()
  WaitFor(() => len(PlacedSigns()) > 0, 'signs return after reset')
  simplegit#HunkStage(1, line('$'))
  WaitFor(() => Git(range_repo, 'diff') ==# '',
    'a whole-file range leaves nothing unstaged')
  var staged = Git(range_repo, 'diff --cached')
  Check(staged =~# '+a2 changed', 'the change hunk is staged')
  Check(staged =~# '-a5', 'the deletion is staged')
  Check(staged =~# '+NEW', 'the insertion is staged')

  # Reverting the same range rebases the other way round and has to restore
  # the file exactly.
  ResetRanged()
  WaitFor(() => len(PlacedSigns()) > 0, 'signs return before the revert')
  simplegit#HunkUndo(1, line('$'))
  WaitFor(() => readfile(ranged) == committed, 'a range revert restores the file')
  Check(getline(1, '$') == committed, 'and the buffer follows')

  # The text objects answer from the same hunk list.
  ResetRanged()
  WaitFor(() => len(PlacedSigns()) > 0, 'signs return before the text object')
  cursor(8, 1)
  simplegit#SelectHunk()
  Check(mode() =~# '^[vV]', 'ih selects linewise (mode ' .. mode() .. ')')
  execute "normal! \<Esc>"
  Check(line("'<") == 8 && line("'>") == 8, 'ih covers exactly the inserted line')
  cursor(1, 1)
  simplegit#SelectHunk()
  Check(mode() !~# '^[vV]', 'ih outside a hunk selects nothing')

  # --- The daemon reports changes made outside Vim ---------------------------
  # system() fires no autocommand: no FocusGained (which a terminal Vim may
  # never see at all), no ShellCmdPost, no keypress. The only thing that can
  # move these signs is the daemon noticing the index move and pushing it.
  ResetRanged()
  WaitFor(() => len(PlacedSigns()) > 0, 'signs before the external change')
  Git(range_repo, 'add ranged.txt')
  WaitFor(() => len(PlacedSigns()) == 0,
    'a git command run outside Vim updates the signs by itself')
endif
bwipeout!
delete(range_repo, 'rf')

simplegit#Disable()

if len(errors) > 0
  writefile(errors, '/dev/stderr')
  cquit!
endif
qall!

" End-to-end commit flow against the real daemon.
"
" Drives :SimpleGitCommit in a throwaway repository: compose a message in the
" scratch buffer, :w to commit, and check that git actually recorded it --
" including the body, which is why the message travels over the daemon's stdin
" rather than as an argv entry.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_commit.vim

set nocompatible
set nomore
set hidden

let s:root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/commit-errors.log')

let s:daemon = s:root . '/lib/simplegit-daemon'
if !executable(s:daemon)
  let s:daemon = s:root . '/target/release/simplegit-daemon'
endif
if !executable(s:daemon) || !executable('git')
  " Nothing to drive; a build-less checkout should not fail the suite.
  qall!
endif
let g:simplegit_daemon_path = s:daemon
runtime plugin/simplegit.vim

" ---------------------------------------------------------------- fixture ---

let s:repo = tempname()
call mkdir(s:repo, 'p')
function! s:Git(args) abort
  return system('git -C ' . shellescape(s:repo) . ' ' . a:args)
endfunction
call s:Git('init -q .')
call s:Git('config user.email test@example.com')
call s:Git('config user.name "Test User"')
call writefile(['first line'], s:repo . '/tracked.txt')
call s:Git('add tracked.txt')

" A decoy repository, used as the working directory for the whole test.
"
" This test drives real `git commit`. Two things follow. First, if the plugin
" resolves the wrong repository the damage must land in a throwaway, never in
" the checkout under test -- an earlier version of this feature did exactly
" that and rewrote this repository's own HEAD. Second, cwd must NOT be the
" fixture, or a plugin that wrongly falls back to getcwd() would look correct.
let s:decoy = tempname()
call mkdir(s:decoy, 'p')
call system('git -C ' . shellescape(s:decoy) . ' init -q .')
call system('git -C ' . shellescape(s:decoy) . ' config user.email decoy@example.com')
call system('git -C ' . shellescape(s:decoy) . ' config user.name Decoy')
call writefile(['decoy'], s:decoy . '/decoy.txt')
call system('git -C ' . shellescape(s:decoy) . ' add decoy.txt')
let s:saved_cwd = getcwd()
execute 'cd ' . fnameescape(s:decoy)

function! s:DecoyCommits() abort
  return len(filter(split(system('git -C ' . shellescape(s:decoy) . ' log --oneline'), "\n"),
        \ 'v:val !=# ""'))
endfunction

function! s:Wait(expr, ms) abort
  let l:i = 0
  while l:i < a:ms / 20
    if eval(a:expr)
      return 1
    endif
    sleep 20m
    let l:i += 1
  endwhile
  return eval(a:expr)
endfunction

function! s:CommitBufWin() abort
  for l:w in getwininfo()
    if bufname(l:w.bufnr) ==# 'simplegit://commit'
      return l:w.winid
    endif
  endfor
  return 0
endfunction

" Locate the message view across tabs; asynchronous replies are required to
" close it in place without changing whatever window is currently focused.
function! s:FocusCommit() abort
  let l:win = s:CommitBufWin()
  if l:win > 0
    call win_gotoid(l:win)
  endif
  return l:win
endfunction

function! s:LogCount() abort
  return len(filter(split(s:Git('log --oneline'), "\n"), 'v:val !=# ""'))
endfunction

" ------------------------------------------------------------- first commit ---

execute 'edit ' . fnameescape(s:repo . '/tracked.txt')
call simplegit#Enable()
call s:Wait('0', 800)

SimpleGitCommit
call assert_true(s:FocusCommit() > 0, 'the commit buffer opens')
call assert_equal('gitcommit', &filetype, 'the buffer uses the gitcommit filetype')
stopinsert

" A message with a body: the daemon must preserve the blank line and the
" second paragraph, which argv-based quoting tends to mangle.
call setline(1, ['Add tracked file', '', 'The body survives the round trip.'])
write
" Move away before the daemon replies. Closing the accepted message in its
" originating tab must not pull focus back from this new tab.
tabnew
let s:away_tab = tabpagenr()
let s:away_win = win_getid()
let s:away_buf = bufnr('%')
" The buffer closing is the completion signal: git records the commit before
" the daemon's reply reaches Vim, so polling git log alone would race ahead of
" the reply and leave a pending close to fire during the next section.
call assert_true(s:Wait('s:CommitBufWin() == 0', 5000), 'the commit completes')
call assert_equal(s:away_tab, tabpagenr(), 'commit completion preserves the current tab')
call assert_equal(s:away_win, win_getid(), 'commit completion preserves the current window')
call assert_equal(s:away_buf, bufnr('%'), 'commit completion preserves the current buffer')
tabclose
call assert_true(s:LogCount() >= 1, 'the commit lands')

let s:body = s:Git('log -1 --pretty=%B')
call assert_true(s:body =~# 'Add tracked file', 'the subject is recorded')
call assert_true(s:body =~# 'The body survives the round trip\.', 'the body is recorded')

" Comment lines from the help block must never reach the message.
call assert_false(s:body =~# 'Lines starting with', 'comment lines are stripped')

" ------------------------------------------------------- empty message ---

let s:before = s:LogCount()
SimpleGitCommit
call assert_true(s:FocusCommit() > 0, 'the commit buffer reopens')
stopinsert
" Only comments: nothing to commit.
call setline(1, ['# just a comment', '#'])
write
sleep 500m
call assert_equal(s:before, s:LogCount(), 'a comment-only message commits nothing')
call assert_true(s:CommitBufWin() > 0, 'the buffer stays open so the message is not lost')
call assert_false(&modified, 'the buffer is not left modified')
" Abort it.
call s:FocusCommit()
call setline(1, [''])
setlocal nomodified
close

" ------------------------------------------------------------------ amend ---

call writefile(['first line', 'second line'], s:repo . '/tracked.txt')
call s:Git('add tracked.txt')
edit!
let s:before = s:LogCount()

SimpleGitCommit!
call assert_true(s:FocusCommit() > 0, 'the amend buffer opens')
stopinsert
" The previous message is fetched asynchronously and pre-filled, so an amend
" edits the existing message rather than silently replacing it. This also pins
" down which repository the commit buffer belongs to: the scratch windows have
" no file name, so resolving it from expand('%:p:h') alone picked up whatever
" repository Vim was started in.
call assert_true(s:Wait('getline(1) =~# "Add tracked file"', 3000),
      \ 'amend pre-fills the previous message')

call s:FocusCommit()
call setline(1, 'Add tracked file, amended')
write
call assert_true(s:Wait('s:CommitBufWin() == 0', 5000), 'the amend completes')
call assert_true(s:Git('log -1 --pretty=%s') =~# 'amended', 'the amend rewrites the subject')
call assert_equal(s:before, s:LogCount(), 'amending does not add a commit')

" ------------------------------------------------- commit from the status view ---

" The scratch windows have no file name, so expand('%:p:h') on them is not a
" directory. Resolving the repository from that alone fell through to getcwd()
" -- which is the decoy here. `c` in the status window is the primary entry
" point for committing, so this is the case that matters most.
call writefile(['first line', 'second line', 'third line'], s:repo . '/tracked.txt')
call s:Git('add tracked.txt')
edit!
SimpleGitStatus
call assert_true(s:Wait('bufname("%") ==# "simplegit://status"', 4000),
      \ 'the status view opens and takes focus')

let s:before = s:LogCount()
let s:decoy_before = s:DecoyCommits()
call simplegit#Commit(v:false)
call assert_true(s:FocusCommit() > 0, 'commit opens from the status view')
stopinsert
call setline(1, 'Committed from the status view')
write
call assert_true(s:Wait('s:CommitBufWin() == 0', 5000), 'the status-view commit completes')

call assert_equal(s:before + 1, s:LogCount(),
      \ 'the commit landed in the repository the status view is showing')
call assert_equal(s:decoy_before, s:DecoyCommits(),
      \ 'nothing was committed into the working directory repository')

" ----------------------------------------------------------------- teardown ---

call simplegit#Disable()
execute 'cd ' . fnameescape(s:saved_cwd)
call delete(s:repo, 'rf')
call delete(s:decoy, 'rf')

if len(v:errors)
  call writefile(v:errors, s:root . '/tests/commit-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!

" Real Vim + installed compiled daemon + disposable Git repository.
set nocompatible nomore
set fileformats=dos,unix
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
let s:daemon = s:root .. '/lib/simplegit-daemon'
call assert_true(executable(s:daemon), 'installed preview daemon is required')
let g:simplegit_daemon_path = s:daemon
let g:simplegit_enable_default_mappings = 0
let g:simplegit_hunk_signs = 0
let g:simplegit_line_blame = 0
runtime plugin/simplegit.vim

function! s:Await(condition, label)
  for i in range(300)
    if call(a:condition, [])
      return 1
    endif
    sleep 10m
  endfor
  call assert_report('timeout: ' .. a:label)
  return 0
endfunction

let s:repo = tempname()
call mkdir(s:repo, 'p', 0700)
let s:file = s:repo .. '/chosen.txt'
let s:index = s:repo .. '/.git/index'
let s:entered = s:repo .. '/entered'
let s:release = s:repo .. '/release'
let s:wrapper = s:repo .. '/delay-preview'
let s:attempts = s:repo .. '/attempts'
let s:done = s:repo .. '/done'
try
  let s:git = 'git -C ' .. shellescape(s:repo) .. ' '
  call system(s:git .. 'init -q')
  call system(s:git .. 'config core.autocrlf false')
  call writefile(["one\r", 'tail'], s:file, 'b')
  call system(s:git .. 'add -- chosen.txt')
  call assert_equal(0, v:shell_error)
  call writefile(["one\r", "SELECT\r", "NO-SELECT\r", 'tail'], s:file, 'b')
  let s:index_bytes = readblob(s:index)
  let s:saved_bytes = readblob(s:file)
  execute 'edit ' .. fnameescape(s:file)
  call assert_equal('dos', &fileformat)
  call assert_false(&endofline)
  let s:origin = win_getid()
  let s:source = bufnr()
  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'real selected-line preview')
    call assert_true(index(getline(1, '$'), "+SELECT\r") >= 0, 'selected CRLF row')
    call assert_equal(-1, index(getline(1, '$'), "+NO-SELECT\r"))
    call assert_match('^saved [0-9a-f]\+$', getline(6))
    call assert_false(&modifiable)
    call assert_equal(2, exists(':SimpleGitStageReviewedLines'))
    call test_feedinput("\<CR>")
    SimpleGitStageReviewedLines
    call assert_equal(s:index_bytes, readblob(s:index), 'default cancel leaves index unchanged')
    call assert_equal(-1, stridx(execute('messages'), 'review or source changed'), 'cancel reached dialog')
    close
    call assert_equal(0, exists(':SimpleGitStageReviewedLines'), 'command belongs only to live preview')
  endif
  call assert_equal(s:origin, win_getid())
  call assert_equal(s:index_bytes, readblob(s:index), 'index unchanged')
  call assert_equal(s:saved_bytes, readblob(s:file), 'file unchanged')

  " Another process can replace a saved file without changing Vim's tick.
  let s:tick = b:changedtick
  call writefile(["one\r", "OTHER\r", "NO-SELECT\r", 'tail'], s:file, 'b')
  2SimpleGitSelectedLinesPreview
  call s:Await({-> execute('messages') =~# 'saved bytes no longer match'}, 'external source mismatch')
  call assert_equal(s:tick, b:changedtick)
  call assert_equal(s:origin, win_getid())
  call assert_equal(s:index_bytes, readblob(s:index))
  call writefile(["one\r", "SELECT\r", "NO-SELECT\r", 'tail'], s:file, 'b')
  edit!

  " Delay delivery without stubbing the daemon or Git. Capture input exactly,
  " then release the genuine process with those bytes on stdin.
  call writefile(['#!/bin/sh',
        \ 'if test "$1" != --preview-selected-buffer-lines; then exec ' .. shellescape(s:daemon) .. ' "$@"; fi',
        \ 'echo start >>' .. shellescape(s:attempts),
        \ 'head -c "$2" >' .. shellescape(s:repo .. '/input'),
        \ 'touch ' .. shellescape(s:entered),
        \ 'while ! test -e ' .. shellescape(s:release) .. '; do sleep 0.01; done',
        \ shellescape(s:daemon) .. ' "$@" <' .. shellescape(s:repo .. '/input'),
        \ 'rc=$?; touch ' .. shellescape(s:done) .. '; exit "$rc"'], s:wrapper)
  call setfperm(s:wrapper, 'rwx------')
  let g:simplegit_daemon_path = s:wrapper

  2SimpleGitSelectedLinesPreview
  call s:Await({-> filereadable(s:entered)}, 'changedtick request reached real wrapper')
  let s:tick = b:changedtick
  call append('$', 'transient')
  call deletebufline(s:source, '$')
  set nomodified
  call assert_notequal(s:tick, b:changedtick)
  call writefile([], s:release)
  call s:Await({-> filereadable(s:done)}, 'stale response from real daemon')
  sleep 100m
  call assert_equal(s:origin, win_getid(), 'changed tick must suppress real result')
  call assert_equal(1, winnr('$'))
  call delete(s:entered)
  call delete(s:release)
  call delete(s:done)

  2SimpleGitSelectedLinesPreview
  call s:Await({-> filereadable(s:entered)}, 'origin-window request reached real wrapper')
  new
  let s:other = win_getid()
  wincmd p
  call assert_equal(s:origin, win_getid(), 'returned to same origin before release')
  3SimpleGitSelectedLinesPreview
  call assert_match('previous request still processing', execute('messages'))
  sleep 20m
  call assert_equal(['start', 'start'], readfile(s:attempts), 'only one helper at a time')
  call writefile([], s:release)
  call s:Await({-> filereadable(s:done)}, 'late real response after window left')
  sleep 100m
  call assert_equal(s:origin, win_getid())
  call assert_equal(2, winnr('$'), 'leaving and returning must not reopen stale preview')
  call assert_equal('', getwinvar(s:other, '&buftype'))
  call assert_equal(s:index_bytes, readblob(s:index))
  call assert_equal(s:saved_bytes, readblob(s:file))

  " A second real request must work after cancellation, even when its bytes
  " do not fit in a pipe buffer. No Write autocmd or disk-mutation fallback.
  let g:simplegit_daemon_path = s:daemon
  let s:large = s:repo .. '/large.txt'
  let s:long = repeat('x', 192 * 1024)
  call writefile([s:long, 'tail'], s:large)
  call system(s:git .. 'add -- large.txt')
  call assert_equal(0, v:shell_error)
  call writefile([s:long, 'large SELECT', 'tail'], s:large)
  execute 'edit ' .. fnameescape(s:large)
  call setline(2, 'unsaved')
  2SimpleGitSelectedLinesPreview
  call assert_match('use an unmodified, saved local file', execute('messages'))
  call assert_equal('unsaved', getline(2))
  call assert_equal(s:origin, win_getid())
  edit!
  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'large confirmed buffer frame')
    call assert_true(index(getline(1, '$'), '+large SELECT') >= 0)
    close
  endif
  execute 'edit ' .. fnameescape(s:file)
  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'source-edit confirmation review')
    call win_execute(s:origin, "call setline(2, 'new unsaved source')")
    SimpleGitStageReviewedLines
    call assert_match('review or source changed', execute('messages'))
    close
  endif
  call assert_equal(s:saved_bytes, readblob(s:file))
  edit!

  " A mutated preview must not act on its previous hidden proposal.
  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'changed review text')
    setlocal modifiable
    call setline('$', 'tampered review')
    setlocal nomodifiable nomodified
    let s:messages_before = execute('messages')
    SimpleGitStageReviewedLines
    call assert_notequal(s:messages_before, execute('messages'))
    call assert_equal("one\r\ntail", system(s:git .. 'show :chosen.txt'))
    close
  endif

  " Another Git writer after rendering must not stage the old patch, even
  " when the selected file and its Vim view themselves are unchanged.
  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'index-race confirmation review')
    call writefile(['peer stage'], s:repo .. '/peer.txt')
    call system(s:git .. 'add -- peer.txt')
    let s:peer_index = readblob(s:index)
    call test_feedinput('s')
    SimpleGitStageReviewedLines
    call s:Await({-> execute('messages') =~# 'reviewed index or content changed'}, 'native stale-stage refusal')
    call assert_equal(s:peer_index, readblob(s:index))
    call assert_equal("one\r\ntail", system(s:git .. 'show :chosen.txt'))
    close
  endif

  2SimpleGitSelectedLinesPreview
  if s:Await({-> &buftype ==# 'nofile'}, 'current confirmation review')
    call test_feedinput('s')
    SimpleGitStageReviewedLines
    call s:Await({-> execute('messages') =~# 'Selected lines staged: chosen.txt'}, 'real native stage receipt')
    call assert_equal("one\r\nSELECT\r\ntail", system(s:git .. 'show :chosen.txt'))
    call assert_equal("peer stage\n", system(s:git .. 'show :peer.txt'))
    call assert_equal(s:saved_bytes, readblob(s:file), 'worktree unchanged after staging')
    let s:staged_index = readblob(s:index)
    SimpleGitStageReviewedLines
    call assert_equal(s:staged_index, readblob(s:index), 'one shot review')
    close
  endif
finally
  call delete(s:repo, 'rf')
endtry
if len(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!

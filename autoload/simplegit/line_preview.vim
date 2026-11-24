vim9script

# Separate, one-shot review and confirmed stage. Never falls back to a hunk action.
const ROOT = expand('<sfile>:p:h:h:h')
const FILE_LIMIT = 256 * 1024
const ROW_LIMIT = 16384
const OUTPUT_LIMIT = 1024 * 1024 + 8192
const WAIT_NOTICE_MS = 10000
var active: dict<any> = {}
var review: dict<any> = {}
var staging: dict<any> = {}

def Warn(message: string)
  echohl WarningMsg
  echomsg 'SimpleGit selected-line preview: ' .. message
  echohl None
enddef

def Binary(): string
  var custom = get(g:, 'simplegit_daemon_path', '')
  if type(custom) == v:t_string && custom !=# ''
    return executable(custom) ? fnamemodify(custom, ':p') : ''
  endif
  for path in [ROOT .. '/lib/simplegit-daemon',
      ROOT .. '/target/release/simplegit-daemon', ROOT .. '/target/debug/simplegit-daemon']
    if executable(path)
      return path
    endif
  endfor
  return exepath('simplegit-daemon')
enddef

def StillWanted(request: dict<any>): bool
  return active is request
      && !request.discarded
      && win_getid() == request.win
      && bufnr('%') == request.buffer
      && b:changedtick == request.tick
      && !&modified
      && expand('%:p') ==# request.path
      && empty(get(b:, 'vimrc_remote', {}))
      && [&encoding, &fileformat, &fileencoding, &bomb, &endofline, &binary, &buftype]
        ==# request.shape
enddef

export def Cancel()
  if empty(active)
    return
  endif
  # Do not kill the helper: abrupt termination could leave its private
  # temporary diff inputs behind. Keep one slot until it has cleaned up.
  active.discarded = true
  active.stdout = ''
  active.stderr = ''
enddef

augroup simplegit_selected_line_preview
  autocmd!
  autocmd WinLeave,BufLeave,TabLeave * call simplegit#line_preview#Cancel()
augroup END

# Read only the fixed metadata rows, never search the rendered patch for IDs.
def HeaderId(row: string, label: string): string
  return matchstr(row, '^' .. label .. ' \zs\%([0-9a-f]\{40}\|[0-9a-f]\{64}\)$')
enddef

def BoundReview(request: dict<any>): bool
  var origin = getwininfo(request.win)
  return review is request
      && win_getid() == request.review_win && bufnr('%') == request.review_buf
      && &buftype ==# 'nofile' && b:changedtick == request.review_tick && !&modifiable && !&modified
      && !empty(origin) && origin[0].bufnr == request.buffer
      && bufloaded(request.buffer)
      && getbufvar(request.buffer, 'changedtick') == request.tick
      && !getbufvar(request.buffer, '&modified')
      && fnamemodify(bufname(request.buffer), ':p') ==# request.path
      && empty(getbufvar(request.buffer, 'vimrc_remote', {}))
      && [&encoding, getbufvar(request.buffer, '&fileformat'),
        getbufvar(request.buffer, '&fileencoding'), getbufvar(request.buffer, '&bomb'),
        getbufvar(request.buffer, '&endofline'), getbufvar(request.buffer, '&binary'),
        getbufvar(request.buffer, '&buftype')] ==# request.shape
      && Binary() ==# request.exe
enddef

def StageFinish(result: dict<any>)
  if staging isnot result || !result.closed || !has_key(result, 'exit')
    return
  endif
  staging = {}
  if result.exit == 0 && result.stdout ==# result.receipt .. "\n" && !result.overflow
    echomsg result.receipt
    return
  endif
  var detail = split(result.stderr, "\n")
  Warn(empty(detail) ? 'staging not confirmed; check the Git index before retrying'
    : substitute(detail[0], '[[:cntrl:]]', ' ', 'g') .. '; check the index before retrying')
enddef

def StageOutput(result: dict<any>, key: string, chunk: string)
  if staging isnot result || result.overflow
    return
  endif
  if strlen(result[key]) + strlen(chunk) > 8192
    result.overflow = true
    return
  endif
  result[key] ..= chunk
enddef

def StageClose(result: dict<any>)
  result.closed = true
  StageFinish(result)
enddef

def StageExit(result: dict<any>, status: number)
  result.exit = status
  StageFinish(result)
enddef

export def StageReviewed()
  if !empty(staging)
    Warn('a confirmed stage is still processing; check the receipt first')
    return
  endif
  var request = review
  if empty(request) || !BoundReview(request)
    Warn('review or source changed; open a fresh preview')
    return
  endif
  if confirm(printf('Stage this reviewed patch for %s (lines %d–%d)?',
        request.file, request.first, request.last), "&Cancel\n&Stage", 1) != 2
    return
  endif
  if !BoundReview(request) || !empty(staging)
    Warn('review or source changed; open a fresh preview')
    return
  endif
  # A confirmed review is single-use even if launch fails. Git independently
  # revalidates the exact disk bytes and whole index under its own lock.
  review = {}
  var result: dict<any> = {
    stdout: '', stderr: '', closed: false, overflow: false,
    receipt: 'Selected lines staged: ' .. request.file,
  }
  staging = result
  try
    var started = job_start([request.exe, '--stage-selected-lines-confirmed',
      request.index_id, request.saved_id, request.proposed_id, string(request.first),
      string(request.last), '--', request.path], {
      noblock: 1, stoponexit: '', in_io: 'null', out_mode: 'raw', err_mode: 'raw',
      out_cb: (_, chunk) => StageOutput(result, 'stdout', chunk),
      err_cb: (_, chunk) => StageOutput(result, 'stderr', chunk),
      close_cb: (_) => StageClose(result),
      exit_cb: (_, status) => StageExit(result, status),
    })
    if job_status(started) ==# 'fail'
      staging = {}
      Warn('could not start confirmed staging; open a fresh preview')
    endif
  catch
    staging = {}
    Warn('staging not confirmed; check the Git index before retrying')
  endtry
enddef

def Finish(request: dict<any>)
  # Vim can deliver exit before the channel close (and before final stdout).
  if active isnot request || !request.closed || !has_key(request, 'exit')
    return
  endif
  var current = StillWanted(request)
  active = {}
  timer_stop(request.timer)
  if !current
    return
  endif
  if request.exit != 0 || stridx(request.stdout, "Selected-line preview only (no changes)\n") != 0
    var detail = split(request.stderr, "\n")
    Warn(empty(detail) ? 'no patch returned; rebuild the installed daemon and retry'
      : substitute(detail[0], '[[:cntrl:]]', ' ', 'g'))
    return
  endif
  noautocmd botright new
  resize 12
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  noautocmd setlocal filetype=diff
  var rows = split(request.stdout, "\n", true)
  setline(1, rows)
  request.stdout = ''
  setlocal nomodifiable nomodified
  nnoremap <silent><buffer> q <Cmd>close<CR>
  normal! gg
  review = {}
  if len(rows) < 10 || rows[2] !~# '^path [ -~]\+$'
    return
  endif
  request.saved_id = HeaderId(rows[5], 'saved')
  request.proposed_id = HeaderId(rows[6], 'proposed')
  request.index_id = HeaderId(rows[7], 'index-snapshot')
  if empty(request.index_id) || len(request.saved_id) != len(request.index_id)
      || len(request.proposed_id) != len(request.index_id)
    return
  endif
  request.file = strpart(rows[2], 5)
  request.review_win = win_getid()
  request.review_buf = bufnr('%')
  request.review_tick = b:changedtick
  review = request
  command! -buffer SimpleGitStageReviewedLines call simplegit#line_preview#StageReviewed()
  nnoremap <silent><buffer> S <Cmd>SimpleGitStageReviewedLines<CR>
enddef

def Append(request: dict<any>, key: string, chunk: string)
  if active isnot request || request.discarded
    return
  endif
  var limit = key ==# 'stdout' ? OUTPUT_LIMIT : 8192
  if strlen(request[key]) + strlen(chunk) > limit
    var current = StillWanted(request)
    Cancel()
    if current
      Warn('daemon output exceeded the preview budget')
    endif
    return
  endif
  request[key] ..= chunk
enddef

def Closed(request: dict<any>)
  request.closed = true
  Finish(request)
enddef

def Exited(request: dict<any>, status: number)
  request.exit = status
  Finish(request)
enddef

def Timeout(request: dict<any>)
  if active is request
    var current = StillWanted(request)
    Cancel()
    if current
      Warn('still processing; the pending result was discarded')
    endif
  endif
enddef

export def Start(first: number, last: number)
  if !empty(active)
    Cancel()
    Warn('previous request still processing; retry after it finishes')
    return
  endif
  if !has('linux')
    Warn('requires the Linux x86-64 preview daemon')
    return
  endif
  var path = expand('%:p')
  if &buftype !=# '' || &modified || &binary || path ==# ''
      || bufname() =~# '^\a[[:alnum:]+.-]*://'
      || !empty(get(b:, 'vimrc_remote', {}))
    Warn('use an unmodified, saved local file')
    return
  endif
  if &encoding !=# 'utf-8' || index(['', 'utf-8'], &fileencoding) < 0
      || index(['unix', 'dos'], &fileformat) < 0
    Warn('only UTF-8 with LF or CRLF is supported')
    return
  endif
  var size = getfsize(path)
  var offset = line2byte(line('$') + 1)
  if line('$') > ROW_LIMIT || size < 0 || size > FILE_LIMIT
      || offset < 0 || offset > FILE_LIMIT + 3
    Warn('file exceeds the preview budget or is unavailable')
    return
  endif
  # Limit allocation while copying the buffer as well as on the daemon side.
  # A newline inside a Vim buffer row represents a NUL on disk, not a separator.
  var sep = &fileformat ==# 'dos' ? "\r\n" : "\n"
  var prefix = &bomb ? "\ufeff" : ''
  var byte_count = strlen(prefix) + (line('$') - 1 + (&endofline ? 1 : 0)) * strlen(sep)
  var rows: list<string> = []
  for number in range(1, line('$'))
    var row = getline(number)
    byte_count += strlen(row)
    if byte_count > FILE_LIMIT || stridx(row, "\n") >= 0
      Warn('buffer exceeds the preview budget or is not plain text')
      return
    endif
    rows->add(row)
  endfor
  var bytes = prefix .. rows->join(sep) .. (&endofline ? sep : '')
  var exe = Binary()
  if exe ==# ''
    Warn('daemon unavailable; run ./install.sh')
    return
  endif
  var request: dict<any> = {
    win: win_getid(), buffer: bufnr('%'), tick: b:changedtick, path: path,
    first: first, last: last, exe: exe,
    shape: [&encoding, &fileformat, &fileencoding, &bomb, &endofline, &binary, &buftype],
    stdout: '', stderr: '', closed: false, discarded: false,
  }
  active = request
  request.timer = timer_start(WAIT_NOTICE_MS, (_) => Timeout(request))
  var started: job = null_job
  try
    started = job_start([exe, '--preview-selected-buffer-lines', string(byte_count),
      string(first), string(last), '--', path], {
      noblock: 1, stoponexit: '', in_mode: 'raw', out_mode: 'raw', err_mode: 'raw',
      out_cb: (_, chunk) => Append(request, 'stdout', chunk),
      err_cb: (_, chunk) => Append(request, 'stderr', chunk),
      close_cb: (_) => Closed(request),
      exit_cb: (_, status) => Exited(request, status),
    })
    if job_status(started) ==# 'fail'
      timer_stop(request.timer)
      active = {}
      Warn('could not start the preview daemon; run ./install.sh or retry')
      return
    endif
    # The child reads exactly byte_count. Closing stdin now could discard a
    # queued remainder of a large nonblocking write.
    ch_sendraw(job_getchannel(started), bytes)
  catch
    if started != null_job && job_status(started) ==# 'run'
      Cancel()
      # An incomplete frame must not hold the helper open indefinitely.
      silent! ch_close_in(job_getchannel(started))
    else
      timer_stop(request.timer)
      active = {}
    endif
    Warn('could not exchange buffer bytes with the preview daemon; run ./install.sh or retry')
  endtry
enddef

# Also compile the cold confirmation path in the defcompile gate.
defcompile

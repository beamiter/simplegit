vim9script

# Separate, one-shot read-only operation. Never falls back to a hunk action.
const ROOT = expand('<sfile>:p:h:h:h')
const FILE_LIMIT = 256 * 1024
const ROW_LIMIT = 16384
const OUTPUT_LIMIT = 1024 * 1024 + 8192
const WAIT_NOTICE_MS = 10000
var active: dict<any> = {}

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
  setline(1, split(request.stdout, "\n", true))
  setlocal nomodifiable nomodified
  nnoremap <silent><buffer> q <Cmd>close<CR>
  normal! gg
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

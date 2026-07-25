vim9script

# =============================================================
# Simplegit — Git superpowers for Vim 9 (blame, history, diff)
# Rendering stays in Vim9script; every git invocation runs in an
# asynchronous Rust daemon so editing never waits on git.
# =============================================================

# ----------- Daemon state -----------
var s_enabled: bool = false
var s_job: any = v:null
var s_running: bool = false
var s_job_generation: number = 0
var s_next_id: number = 0
var s_last_error: string = ''
var s_daemon_version: string = ''
var s_daemon_protocol: number = 0
var s_daemon_ready: bool = false
var s_daemon_incompatible: bool = false

# Correlate asynchronous replies: id -> {kind, ...context}
var s_pending: dict<dict<any>> = {}
# Requests issued before the version handshake completed.
var s_wait_queue: list<dict<any>> = []

# ----------- Blame state -----------
# bufnr (string) -> {lines: list<string>, commits: dict<any>, failed: bool}
var s_blame_cache: dict<dict<any>> = {}
var s_blame_inflight: dict<bool> = {}
var s_blame_timer: number = 0
var s_line_blame_on: bool = true

const UNCOMMITTED = '0000000000000000000000000000000000000000'
const PROP_TYPE = 'simplegit_line_blame'

# =============================================================
# Small helpers
# =============================================================
def ConfBool(name: string, default_val: bool): bool
  var value = get(g:, name, default_val)
  if type(value) == v:t_bool
    return value
  endif
  if type(value) == v:t_number
    return value != 0
  endif
  return default_val
enddef

def ConfNum(name: string, default_val: number): number
  var value = get(g:, name, default_val)
  return type(value) == v:t_number && value > 0 ? value : default_val
enddef

def DebugLog(message: string)
  s_last_error = message
  if ConfBool('simplegit_debug', false)
    echomsg '[SimpleGit] ' .. message
  endif
enddef

def Warn(message: string)
  echohl WarningMsg
  echomsg '[SimpleGit] ' .. message
  echohl None
enddef

def IsWin(): bool
  return has('win32') || has('win64')
enddef

def BufFilePath(bufnr: number): string
  if !bufexists(bufnr) || getbufvar(bufnr, '&buftype') !=# ''
    return ''
  endif
  var name = fnamemodify(bufname(bufnr), ':p')
  return filereadable(name) ? name : ''
enddef

def ShortSha(sha: string): string
  return strpart(sha, 0, 7)
enddef

def TimeAgo(epoch: number): string
  var diff = localtime() - epoch
  if diff < 0
    diff = 0
  endif
  if diff < 60
    return 'just now'
  elseif diff < 3600
    var n = diff / 60
    return n .. (n == 1 ? ' minute ago' : ' minutes ago')
  elseif diff < 86400
    var n = diff / 3600
    return n .. (n == 1 ? ' hour ago' : ' hours ago')
  elseif diff < 604800
    var n = diff / 86400
    return n .. (n == 1 ? ' day ago' : ' days ago')
  elseif diff < 2592000
    var n = diff / 604800
    return n .. (n == 1 ? ' week ago' : ' weeks ago')
  elseif diff < 31536000
    var n = diff / 2592000
    return n .. (n == 1 ? ' month ago' : ' months ago')
  endif
  var n = diff / 31536000
  return n .. (n == 1 ? ' year ago' : ' years ago')
enddef

def CommitDate(epoch: number): string
  return epoch > 0 ? strftime('%Y-%m-%d', epoch) : '          '
enddef

# =============================================================
# Daemon lifecycle (JSON lines over stdin/stdout)
# =============================================================
def FindDaemon(): string
  var override = get(g:, 'simplegit_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif
  var names = IsWin() ? ['lib/simplegit-daemon.exe', 'lib/simplegit-daemon']
        \ : ['lib/simplegit-daemon']
  for name in names
    for p in globpath(&runtimepath, name, false, true)
      if executable(p)
        return p
      endif
    endfor
  endfor
  return ''
enddef

def SendRaw(req: dict<any>): bool
  if !s_running || s_job == v:null
    return false
  endif
  try
    ch_sendraw(s_job, json_encode(req) .. "\n")
    return true
  catch
    DebugLog('failed to send daemon request: ' .. v:exception)
    return false
  endtry
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def ClearPending()
  s_pending = {}
  s_wait_queue = []
  s_blame_inflight = {}
enddef

def StartDaemon(): bool
  if s_running && s_job != v:null
    try
      if job_status(s_job) ==# 'run'
        return true
      endif
    catch
    endtry
  endif
  var cmd = FindDaemon()
  if cmd ==# '' || !executable(cmd)
    DebugLog('daemon not found; run ./install.sh or set g:simplegit_daemon_path')
    return false
  endif
  s_job_generation += 1
  var generation = s_job_generation
  try
    s_job = job_start([cmd], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if generation == s_job_generation
          OnDaemonLine(line)
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        if generation == s_job_generation && line !=# ''
          DebugLog('daemon stderr: ' .. line)
        endif
      },
      exit_cb: (ch, code) => {
        if generation == s_job_generation
          s_running = false
          s_job = v:null
          ClearPending()
          if code != 0
            DebugLog('daemon exited with code ' .. code)
          endif
        endif
      },
      stoponexit: 'term'
    })
    s_running = s_job != v:null && job_status(s_job) ==# 'run'
    if s_running
      s_last_error = ''
      s_daemon_version = ''
      s_daemon_protocol = 0
      s_daemon_ready = false
      s_daemon_incompatible = false
      SendRaw({type: 'version', id: 0})
    endif
  catch
    s_job = v:null
    s_running = false
    DebugLog('failed to start daemon: ' .. v:exception)
  endtry
  return s_running
enddef

# Send a request; queue it while the handshake is still in flight.
def Dispatch(req: dict<any>, ctx: dict<any>): bool
  if !s_running && !StartDaemon()
    return false
  endif
  if s_daemon_incompatible
    return false
  endif
  if !s_daemon_ready
    if len(s_wait_queue) < 32
      s_wait_queue->add({req: req, ctx: ctx})
    endif
    return true
  endif
  var id = NextId()
  # Copy into a dict<any>: call sites pass all-string literals whose inferred
  # type would reject the numeric id.
  var wire: dict<any> = extend({}, req)
  wire.id = id
  s_pending[string(id)] = ctx
  if !SendRaw(wire)
    remove(s_pending, string(id))
    return false
  endif
  return true
enddef

def FlushWaitQueue()
  var queued = s_wait_queue
  s_wait_queue = []
  for item in queued
    Dispatch(item.req, item.ctx)
  endfor
enddef

def TakePending(id: number): dict<any>
  var key = string(id)
  if id <= 0 || !has_key(s_pending, key)
    return {}
  endif
  return remove(s_pending, key)
enddef

def OnDaemonLine(line: string)
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    DebugLog('invalid daemon response: ' .. line)
    return
  endtry
  if type(ev) != v:t_dict || type(get(ev, 'type', v:null)) != v:t_string
    DebugLog('malformed daemon response')
    return
  endif
  if ev.type ==# 'version'
    OnVersion(ev)
    return
  endif
  var id = get(ev, 'id', 0)
  if type(id) != v:t_number
    DebugLog('daemon response without a numeric id')
    return
  endif
  var ctx = TakePending(id)
  if empty(ctx)
    DebugLog('ignored stale daemon response ' .. id)
    return
  endif
  if ev.type ==# 'error'
    OnRequestError(ctx, get(ev, 'message', 'unknown error'))
    return
  endif
  if ev.type !=# get(ctx, 'kind', '')
    DebugLog('daemon response type mismatch for request ' .. id)
    return
  endif
  if ev.type ==# 'blame'
    OnBlame(ctx, ev)
  elseif ev.type ==# 'log'
    OnLog(ctx, ev)
  elseif ev.type ==# 'show'
    OnShow(ctx, ev)
  elseif ev.type ==# 'cat'
    OnCat(ctx, ev)
  elseif ev.type ==# 'status'
    OnStatus(ctx, ev)
  endif
enddef

def OnVersion(ev: dict<any>)
  var id = get(ev, 'id', -1)
  var version = get(ev, 'version', '')
  var protocol = get(ev, 'protocol', 0)
  if type(id) == v:t_number && id == 0 && type(version) == v:t_string
        \ && version !=# '' && type(protocol) == v:t_number
    s_daemon_version = version
    s_daemon_protocol = protocol
    if protocol != 1
      s_daemon_ready = false
      s_daemon_incompatible = true
      s_wait_queue = []
      DebugLog('unsupported daemon protocol ' .. protocol .. '; rerun ./install.sh')
    else
      s_daemon_ready = true
      s_daemon_incompatible = false
      s_last_error = ''
      FlushWaitQueue()
    endif
  else
    s_daemon_ready = false
    s_daemon_incompatible = true
    s_wait_queue = []
    DebugLog('malformed daemon version response; rerun ./install.sh')
  endif
enddef

def OnRequestError(ctx: dict<any>, message: any)
  var text = type(message) == v:t_string ? message : string(message)
  if get(ctx, 'kind', '') ==# 'blame'
    var key = string(get(ctx, 'bufnr', -1))
    if has_key(s_blame_inflight, key)
      remove(s_blame_inflight, key)
    endif
    # Remember the failure so cursor movement does not hammer the daemon
    # with requests for files outside any repository.
    s_blame_cache[key] = {failed: true, lines: [], commits: {}}
  endif
  if get(ctx, 'interactive', false)
    Warn(text)
  else
    DebugLog('daemon error: ' .. strtrans(text))
  endif
enddef

# =============================================================
# Blame data
# =============================================================
def ValidBlame(ev: dict<any>): bool
  return type(get(ev, 'lines', v:null)) == v:t_list
        \ && type(get(ev, 'commits', v:null)) == v:t_dict
enddef

def RequestBlame(bufnr: number, purpose: string, interactive: bool): bool
  var path = BufFilePath(bufnr)
  if path ==# ''
    return false
  endif
  var key = string(bufnr)
  if has_key(s_blame_inflight, key)
    return true
  endif
  var ok = Dispatch({type: 'blame', path: path},
    {kind: 'blame', bufnr: bufnr, purpose: purpose, interactive: interactive})
  if ok
    s_blame_inflight[key] = true
  endif
  return ok
enddef

def OnBlame(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var key = string(bufnr)
  if has_key(s_blame_inflight, key)
    remove(s_blame_inflight, key)
  endif
  if !ValidBlame(ev)
    DebugLog('ignored malformed blame response')
    return
  endif
  if !bufexists(bufnr)
    return
  endif
  if len(s_blame_cache) >= 64 && !has_key(s_blame_cache, key)
    remove(s_blame_cache, keys(s_blame_cache)[0])
  endif
  s_blame_cache[key] = {failed: false, lines: ev.lines, commits: ev.commits}
  var purpose = get(ctx, 'purpose', 'virtual')
  if purpose ==# 'virtual'
    ShowLineBlameNow()
  elseif purpose ==# 'window'
    OpenBlameWindow(bufnr)
  elseif purpose ==# 'popup'
    ShowBlamePopup(bufnr)
  endif
enddef

def BlameFor(bufnr: number): dict<any>
  return get(s_blame_cache, string(bufnr), {})
enddef

def InvalidateBlame(bufnr: number)
  var key = string(bufnr)
  if has_key(s_blame_cache, key)
    remove(s_blame_cache, key)
  endif
enddef

def LineAnnotation(blame: dict<any>, lnum: number): string
  var lines = get(blame, 'lines', [])
  if lnum < 1 || lnum > len(lines)
    return ''
  endif
  var sha = lines[lnum - 1]
  if sha ==# UNCOMMITTED
    return 'Uncommitted changes'
  endif
  var info = get(blame.commits, sha, {})
  if empty(info)
    return ''
  endif
  var author = get(info, 'author', '')
  var when = TimeAgo(get(info, 'time', 0))
  var summary = get(info, 'summary', '')
  return author .. ', ' .. when .. ' • ' .. summary
enddef

# =============================================================
# Inline (current line) blame — GitLens style virtual text
# =============================================================
def VirtualTextSupported(): bool
  return has('textprop') && has('patch-9.0.0067')
enddef

def EnsurePropType()
  if empty(prop_type_get(PROP_TYPE))
    prop_type_add(PROP_TYPE, {highlight: 'SimpleGitBlameVirtual'})
  endif
enddef

def ClearLineBlame(bufnr: number)
  if !VirtualTextSupported() || !bufexists(bufnr)
    return
  endif
  if !empty(prop_type_get(PROP_TYPE))
    prop_remove({type: PROP_TYPE, bufnr: bufnr, all: true})
  endif
enddef

def ShowLineBlameNow()
  if !s_enabled || !s_line_blame_on || !VirtualTextSupported()
    return
  endif
  if mode() !=# 'n'
    return
  endif
  var bufnr = bufnr('%')
  ClearLineBlame(bufnr)
  if getbufvar(bufnr, '&modified') || BufFilePath(bufnr) ==# ''
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame)
    RequestBlame(bufnr, 'virtual', false)
    return
  endif
  if get(blame, 'failed', false)
    return
  endif
  var text = LineAnnotation(blame, line('.'))
  if text ==# ''
    return
  endif
  EnsurePropType()
  prop_add(line('.'), 0, {
    type: PROP_TYPE,
    bufnr: bufnr,
    text: '    ' .. text,
    text_align: 'after',
    text_wrap: 'truncate',
  })
enddef

export def ScheduleLineBlame()
  if !s_enabled || !s_line_blame_on || !VirtualTextSupported()
    return
  endif
  ClearLineBlame(bufnr('%'))
  if !has('timers')
    ShowLineBlameNow()
    return
  endif
  if s_blame_timer != 0
    timer_stop(s_blame_timer)
  endif
  s_blame_timer = timer_start(ConfNum('simplegit_blame_delay', 350), (_) => {
    s_blame_timer = 0
    ShowLineBlameNow()
  })
enddef

export def OnBufWrite()
  var bufnr = bufnr('%')
  InvalidateBlame(bufnr)
  ScheduleLineBlame()
enddef

export def OnBufClose(bufnr: number)
  InvalidateBlame(bufnr)
enddef

export def ToggleLineBlame()
  s_line_blame_on = !s_line_blame_on
  if s_line_blame_on
    ScheduleLineBlame()
    echo '[SimpleGit] line blame on'
  else
    ClearLineBlame(bufnr('%'))
    echo '[SimpleGit] line blame off'
  endif
enddef

# =============================================================
# Blame popup for the current line
# =============================================================
def ShowBlamePopup(bufnr: number)
  if bufnr != bufnr('%')
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame) || get(blame, 'failed', false)
    Warn('no blame information for this buffer')
    return
  endif
  var lines = get(blame, 'lines', [])
  var lnum = line('.')
  if lnum > len(lines)
    Warn('line has no blame information (unsaved changes?)')
    return
  endif
  var sha = lines[lnum - 1]
  if sha ==# UNCOMMITTED
    echo '[SimpleGit] Uncommitted changes'
    return
  endif
  var info = get(blame.commits, sha, {})
  var when = get(info, 'time', 0)
  var text = [
    'Commit  ' .. ShortSha(sha),
    'Author  ' .. get(info, 'author', ''),
    'Date    ' .. (when > 0 ? strftime('%Y-%m-%d %H:%M', when) .. ' (' .. TimeAgo(when) .. ')' : ''),
    '',
    get(info, 'summary', ''),
  ]
  if has('popupwin')
    popup_atcursor(text, {
      padding: [0, 1, 0, 1],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      moved: 'any',
    })
  else
    echo join(text, ' | ')
  endif
enddef

export def BlameLine()
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame)
    if !RequestBlame(bufnr, 'popup', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  ShowBlamePopup(bufnr)
enddef

# =============================================================
# Blame sidebar (whole file)
# =============================================================
def FindBlameWin(bufnr: number): number
  for win in getwininfo()
    if getbufvar(win.bufnr, 'simplegit_blame_src', -1) == bufnr
      return win.winid
    endif
  endfor
  return 0
enddef

def OpenBlameWindow(bufnr: number)
  if bufnr != bufnr('%') || !bufexists(bufnr)
    return
  endif
  var blame = BlameFor(bufnr)
  if empty(blame) || get(blame, 'failed', false)
    Warn('no blame information for this buffer')
    return
  endif
  if getbufvar(bufnr, '&modified')
    Warn('save the buffer first; blame reflects the file on disk')
    return
  endif
  var existing = FindBlameWin(bufnr)
  if existing != 0
    win_gotoid(existing)
    return
  endif

  var lines = get(blame, 'lines', [])
  var commits = get(blame, 'commits', {})
  var display: list<string> = []
  var shas: list<string> = []
  for sha in lines
    shas->add(sha)
    if sha ==# UNCOMMITTED
      display->add('0000000 ~ uncommitted    ')
      continue
    endif
    var info = get(commits, sha, {})
    var author = strcharpart(get(info, 'author', ''), 0, 14)
    display->add(printf('%s %s %-14s', ShortSha(sha), CommitDate(get(info, 'time', 0)), author))
  endfor

  var src_win = win_getid()
  var src_top = line('w0')
  var src_lnum = line('.')
  setwinvar(src_win, '&scrollbind', 1)
  setwinvar(src_win, '&cursorbind', 1)

  var width = ConfNum('simplegit_blame_width', 34)
  silent keepalt vertical topleft new
  execute 'vertical resize ' .. width
  silent execute 'file ' .. fnameescape('simplegit://blame/' .. fnamemodify(bufname(bufnr), ':t'))
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nonumber norelativenumber nowrap nofoldenable foldcolumn=0 signcolumn=no
  setlocal winfixwidth
  setline(1, display)
  setlocal nomodifiable
  b:simplegit_blame_src = bufnr
  b:simplegit_shas = shas
  b:simplegit_src_win = src_win
  setlocal scrollbind cursorbind scrollopt=ver,jump

  syntax match SimpleGitBlameSha /^\x\{7}/
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/
  syntax match SimpleGitBlameUncommitted /^0\{7} \~ uncommitted.*/

  nnoremap <silent><buffer> <CR> <ScriptCmd>BlameWindowShow()<CR>
  nnoremap <silent><buffer> p <ScriptCmd>BlameWindowPopup()<CR>
  nnoremap <silent><buffer> q <ScriptCmd>CloseBlameWindow()<CR>

  # Align the sidebar with the source window before binding takes over.
  execute ':' .. src_lnum
  win_execute(src_win, 'normal! ' .. src_top .. 'zt')
  execute 'normal! ' .. src_top .. 'zt'
  execute ':' .. src_lnum
  syncbind
enddef

def BlameWindowSha(): string
  var shas = get(b:, 'simplegit_shas', [])
  var lnum = line('.')
  if lnum > len(shas)
    return ''
  endif
  return shas[lnum - 1]
enddef

def BlameWindowShow()
  var sha = BlameWindowSha()
  if sha ==# '' || sha ==# UNCOMMITTED
    Warn('no commit under cursor')
    return
  endif
  var src = get(b:, 'simplegit_blame_src', -1)
  var path = BufFilePath(src)
  if path ==# ''
    Warn('source buffer is gone')
    return
  endif
  if !Dispatch({type: 'show', path: path, rev: sha},
      {kind: 'show', interactive: true, title: 'commit ' .. ShortSha(sha)})
    Warn('daemon unavailable')
  endif
enddef

def BlameWindowPopup()
  var sha = BlameWindowSha()
  if sha ==# '' || sha ==# UNCOMMITTED
    return
  endif
  var src = get(b:, 'simplegit_blame_src', -1)
  var blame = BlameFor(src)
  if empty(blame)
    return
  endif
  var info = get(get(blame, 'commits', {}), sha, {})
  var when = get(info, 'time', 0)
  var text = [
    'Commit  ' .. ShortSha(sha),
    'Author  ' .. get(info, 'author', ''),
    'Date    ' .. (when > 0 ? strftime('%Y-%m-%d %H:%M', when) : ''),
    '',
    get(info, 'summary', ''),
  ]
  if has('popupwin')
    popup_atcursor(text, {padding: [0, 1, 0, 1], moved: 'any'})
  else
    echo join(text, ' | ')
  endif
enddef

def CloseBlameWindow()
  var src_win = get(b:, 'simplegit_src_win', 0)
  var blame_win = win_getid()
  if src_win != 0 && win_id2win(src_win) > 0
    setwinvar(src_win, '&scrollbind', 0)
    setwinvar(src_win, '&cursorbind', 0)
  endif
  win_execute(blame_win, 'close')
enddef

export def ToggleBlame()
  var bufnr = bufnr('%')
  # Toggling from inside the sidebar closes it.
  if has_key(b:, 'simplegit_blame_src')
    CloseBlameWindow()
    return
  endif
  var existing = FindBlameWin(bufnr)
  if existing != 0
    win_gotoid(existing)
    CloseBlameWindow()
    return
  endif
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  if getbufvar(bufnr, '&modified')
    Warn('save the buffer first; blame reflects the file on disk')
    return
  endif
  var blame = BlameFor(bufnr)
  if !empty(blame) && !get(blame, 'failed', false)
    OpenBlameWindow(bufnr)
    return
  endif
  if !RequestBlame(bufnr, 'window', true)
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Scratch windows (show / history / status)
# =============================================================
def OpenScratch(name: string, height: number): number
  silent keepalt botright new
  if height > 0
    execute 'resize ' .. height
  endif
  silent execute 'file ' .. fnameescape(name)
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nonumber norelativenumber nofoldenable foldcolumn=0 signcolumn=no
  nnoremap <silent><buffer> q <Cmd>close<CR>
  return bufnr('%')
enddef

def OnShow(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', v:null)
  if type(lines) != v:t_list
    DebugLog('ignored malformed show response')
    return
  endif
  var title = get(ctx, 'title', 'show')
  OpenScratch('simplegit://' .. title, 0)
  setlocal filetype=git
  setline(1, empty(lines) ? ['(empty)'] : lines)
  setlocal nomodifiable
  execute ':1'
enddef

export def Show(rev: string)
  var use_rev = rev ==# '' ? 'HEAD' : rev
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    path = getcwd()
  endif
  if !Dispatch({type: 'show', path: path, rev: use_rev},
      {kind: 'show', interactive: true, title: 'commit ' .. use_rev})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# File history
# =============================================================
def ValidLogEntry(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'sha', v:null)) == v:t_string
        \ && type(get(entry, 'author', v:null)) == v:t_string
        \ && type(get(entry, 'time', v:null)) == v:t_number
        \ && type(get(entry, 'subject', v:null)) == v:t_string
enddef

def OnLog(ctx: dict<any>, ev: dict<any>)
  var entries = get(ev, 'entries', v:null)
  if type(entries) != v:t_list
    DebugLog('ignored malformed log response')
    return
  endif
  var path = get(ctx, 'path', '')
  if empty(entries)
    Warn('no history for ' .. fnamemodify(path, ':t'))
    return
  endif
  var display: list<string> = []
  var shas: list<string> = []
  for entry in entries
    if !ValidLogEntry(entry)
      continue
    endif
    shas->add(entry.sha)
    display->add(printf('%s %s %-16s %s',
      ShortSha(entry.sha), CommitDate(entry.time),
      strcharpart(entry.author, 0, 16), entry.subject))
  endfor
  var height = min([max([len(display), 5]), ConfNum('simplegit_history_height', 15)])
  OpenScratch('simplegit://history/' .. fnamemodify(path, ':t'), height)
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_shas = shas
  b:simplegit_src_path = path

  syntax match SimpleGitBlameSha /^\x\{7}/
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/

  nnoremap <silent><buffer> <CR> <ScriptCmd>HistoryShow(false)<CR>
  nnoremap <silent><buffer> a <ScriptCmd>HistoryShow(true)<CR>
  execute ':1'
enddef

def HistoryShow(whole_commit: bool)
  var shas = get(b:, 'simplegit_shas', [])
  var path = get(b:, 'simplegit_src_path', '')
  var lnum = line('.')
  if lnum > len(shas) || path ==# ''
    return
  endif
  var sha = shas[lnum - 1]
  var req = {type: 'show', path: path, rev: sha}
  if !whole_commit
    req.file = path
  endif
  if !Dispatch(req, {kind: 'show', interactive: true, title: 'commit ' .. ShortSha(sha)})
    Warn('daemon unavailable')
  endif
enddef

export def History()
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var limit = ConfNum('simplegit_history_limit', 200)
  if !Dispatch({type: 'log', path: path, limit: limit},
      {kind: 'log', interactive: true, path: path})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Diff against a revision
# =============================================================
def OnCat(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', v:null)
  if type(lines) != v:t_list
    DebugLog('ignored malformed cat response')
    return
  endif
  var src = get(ctx, 'bufnr', -1)
  var rev = get(ctx, 'rev', 'HEAD')
  if !bufexists(src)
    return
  endif
  var src_win = bufwinid(src)
  if src_win == -1
    Warn('source window is gone')
    return
  endif
  win_gotoid(src_win)
  var src_ft = &filetype
  diffthis
  execute 'silent keepalt vertical leftabove new'
  silent execute 'file ' .. fnameescape('simplegit://' .. rev .. '/' .. fnamemodify(bufname(src), ':t'))
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setline(1, lines)
  setlocal nomodifiable
  execute 'setlocal filetype=' .. fnameescape(src_ft)
  b:simplegit_diff_src = src
  diffthis
  nnoremap <silent><buffer> q <ScriptCmd>CloseDiff()<CR>
  win_gotoid(src_win)
enddef

def CloseDiff()
  var src = get(b:, 'simplegit_diff_src', -1)
  close
  if bufexists(src)
    var src_win = bufwinid(src)
    if src_win != -1
      win_execute(src_win, 'diffoff')
    endif
  endif
enddef

export def Diff(rev: string)
  var bufnr = bufnr('%')
  var path = BufFilePath(bufnr)
  if path ==# ''
    Warn('current buffer has no readable file')
    return
  endif
  var use_rev = rev ==# '' ? 'HEAD' : rev
  if !Dispatch({type: 'cat', path: path, rev: use_rev},
      {kind: 'cat', interactive: true, bufnr: bufnr, rev: use_rev})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Repository status
# =============================================================
def ValidStatusEntry(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'xy', v:null)) == v:t_string
        \ && type(get(entry, 'path', v:null)) == v:t_string
enddef

def OnStatus(ctx: dict<any>, ev: dict<any>)
  var entries = get(ev, 'entries', v:null)
  var branch = get(ev, 'branch', '')
  if type(entries) != v:t_list || type(branch) != v:t_string
    DebugLog('ignored malformed status response')
    return
  endif
  var dir = get(ctx, 'dir', getcwd())
  var display = ['## ' .. (branch ==# '' ? '(no branch)' : branch)]
  var paths: list<string> = ['']
  for entry in entries
    if !ValidStatusEntry(entry)
      continue
    endif
    var label = substitute(entry.xy, '\.', ' ', 'g')
    var line = label .. ' ' .. entry.path
    var orig = get(entry, 'orig', '')
    if type(orig) == v:t_string && orig !=# ''
      line ..= ' <- ' .. orig
    endif
    display->add(line)
    paths->add(entry.path)
  endfor
  if len(display) == 1
    display->add('   (working tree clean)')
    paths->add('')
  endif
  var height = min([max([len(display), 5]), 15])
  OpenScratch('simplegit://status', height)
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_paths = paths
  b:simplegit_dir = dir

  syntax match SimpleGitStatusBranch /^##.*/
  syntax match SimpleGitStatusUntracked /^??.*/
  syntax match SimpleGitStatusConflict /^u\S\+.*/

  nnoremap <silent><buffer> <CR> <ScriptCmd>StatusOpen(false)<CR>
  nnoremap <silent><buffer> d <ScriptCmd>StatusOpen(true)<CR>
  execute ':1'
enddef

def StatusRoot(dir: string): string
  # The daemon reports paths relative to the repository root.
  var root = system('git -C ' .. shellescape(dir) .. ' rev-parse --show-toplevel')
  if v:shell_error != 0
    return dir
  endif
  return trim(root)
enddef

def StatusOpen(diff_it: bool)
  var paths = get(b:, 'simplegit_paths', [])
  var dir = get(b:, 'simplegit_dir', getcwd())
  var lnum = line('.')
  if lnum > len(paths) || paths[lnum - 1] ==# ''
    return
  endif
  var full = StatusRoot(dir) .. '/' .. paths[lnum - 1]
  close
  execute 'edit ' .. fnameescape(full)
  if diff_it
    Diff('')
  endif
enddef

export def Status()
  var dir = expand('%:p:h')
  if dir ==# '' || !isdirectory(dir)
    dir = getcwd()
  endif
  if !Dispatch({type: 'status', path: dir},
      {kind: 'status', interactive: true, dir: dir})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

# =============================================================
# Lifecycle
# =============================================================
export def Enable()
  if s_enabled
    return
  endif
  s_enabled = true
  s_line_blame_on = ConfBool('simplegit_line_blame', true)
  StartDaemon()
  ScheduleLineBlame()
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false
  if s_blame_timer != 0
    timer_stop(s_blame_timer)
    s_blame_timer = 0
  endif
  ClearLineBlame(bufnr('%'))
  Stop()
enddef

export def Stop()
  if s_job != v:null
    try
      job_stop(s_job)
    catch
    endtry
  endif
  s_job = v:null
  s_running = false
  s_daemon_ready = false
  ClearPending()
  s_blame_cache = {}
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def Health()
  var daemon = FindDaemon()
  echo '[SimpleGit] health'
  echo '  enabled:        ' .. (s_enabled ? 'yes' : 'no')
  echo '  daemon binary:  ' .. (daemon ==# '' ? '(not found — run ./install.sh)' : daemon)
  echo '  daemon running: ' .. (s_running ? 'yes' : 'no')
  echo '  daemon version: ' .. (s_daemon_version ==# '' ? 'unknown' : s_daemon_version)
        .. '/' .. s_daemon_protocol
  echo '  virtual text:   ' .. (VirtualTextSupported() ? 'supported' : 'unsupported (needs Vim 9.0.0067+)')
  echo '  popups:         ' .. (has('popupwin') ? 'supported' : 'unsupported')
  echo '  line blame:     ' .. (s_line_blame_on ? 'on' : 'off')
  echo '  cached buffers: ' .. len(s_blame_cache)
  echo '  pending:        ' .. len(s_pending)
  echo '  last message:   ' .. (s_last_error ==# '' ? '(none)' : s_last_error)
enddef

export def DebugStatus()
  Health()
enddef

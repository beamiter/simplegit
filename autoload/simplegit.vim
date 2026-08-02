vim9script


# =============================================================
# Simplegit — Git superpowers for Vim 9 (blame, history, diff)
# Rendering stays in Vim9script; every git invocation runs in an
# asynchronous Rust daemon so editing never waits on git.
# =============================================================

# ----------- Daemon state -----------
var s_enabled: bool = false
var s_next_id: number = 0
var s_last_error: string = ''
var s_daemon_version: string = ''
var s_daemon_protocol: number = 0
var s_daemon_ready: bool = false
var s_daemon_incompatible: bool = false
# Consecutive daemon starts without a completed handshake; a broken binary
# must not be respawned on every request.

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

# ----------- Hunk state -----------
# bufnr (string) -> {failed: bool, hunks: list<dict<any>>}
var s_hunk_cache: dict<dict<any>> = {}
var s_hunk_inflight: dict<bool> = {}
# Buffers that changed again while a hunks request was in flight.
var s_hunk_stale: dict<bool> = {}
var s_hunk_timer: number = 0
var s_signs_on: bool = true
var s_signs_defined: bool = false

const UNCOMMITTED = '0000000000000000000000000000000000000000'
const PROP_TYPE = 'simplegit_line_blame'
const SIGN_GROUP = 'simplegit'

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
  # getbufinfo names are absolute, unlike bufname(), which would resolve
  # relative to whatever the current directory happens to be by now.
  var name = get(get(getbufinfo(bufnr), 0, {}), 'name', '')
  return name !=# '' && filereadable(name) ? name : ''
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
  SetupCore()
  return simplegit#core#FindExe()
enddef

# The supervisor owns the process: liveness via job_status, generation-guarded
# callbacks, exponential-backoff restarts and a crash-loop breaker.  This file
# keeps only the protocol handshake and the request bookkeeping.
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simplegit#core#Setup({
    name: 'SimpleGit',
    exe: 'simplegit-daemon',
    path_var: 'simplegit_daemon_path',
    debug_var: 'simplegit_debug',
    handshake: {request: {type: 'version'}, reply_type: 'version', proto_key: 'protocol'},
    OnEvent: OnDaemonEvent,
    OnExit: OnDaemonExit,
  })
enddef

def SendRaw(req: dict<any>): bool
  return simplegit#core#Send(req)
enddef

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def ClearPending()
  s_pending = {}
  s_wait_queue = []
  s_blame_inflight = {}
  s_hunk_inflight = {}
enddef

def OnDaemonExit(code: number, restarting: bool)
  s_daemon_ready = false
  s_daemon_protocol = 0
  s_daemon_version = ''
  ClearPending()
enddef

def StartDaemon(): bool
  SetupCore()
  if simplegit#core#IsRunning()
    return true
  endif
  s_daemon_ready = false
  s_daemon_incompatible = false
  s_daemon_version = ''
  s_daemon_protocol = 0
  return simplegit#core#Ensure()
enddef

# Send a request; queue it while the handshake is still in flight.
def Dispatch(req: dict<any>, ctx: dict<any>): bool
  if !simplegit#core#IsRunning() && !StartDaemon()
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

def OnDaemonEvent(ev: dict<any>)
  if type(get(ev, 'type', v:null)) != v:t_string
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
  elseif ev.type ==# 'graph_log'
    OnGraphLog(ctx, ev)
  elseif ev.type ==# 'show'
    OnShow(ctx, ev)
  elseif ev.type ==# 'cat'
    OnCat(ctx, ev)
  elseif ev.type ==# 'status'
    OnStatus(ctx, ev)
  elseif ev.type ==# 'hunks'
    OnHunks(ctx, ev)
  elseif ev.type ==# 'hunk_op'
    OnHunkOp(ctx, ev)
  elseif ev.type ==# 'file_op'
    OnFileOp(ctx, ev)
  elseif ev.type ==# 'commit'
    OnCommit(ctx, ev)
  elseif ev.type ==# 'commit_message'
    OnCommitMessage(ctx, ev)
  endif
enddef

def OnVersion(ev: dict<any>)
  # The id is assigned by the supervisor, which has already correlated this
  # reply to its handshake request; only the payload still needs validating.
  var version = get(ev, 'version', '')
  var protocol = get(ev, 'protocol', 0)
  if type(version) == v:t_string && version !=# '' && type(protocol) == v:t_number
    s_daemon_version = version
    s_daemon_protocol = protocol
    if protocol != 5
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
  elseif get(ctx, 'kind', '') ==# 'hunks'
    var key = string(get(ctx, 'bufnr', -1))
    if has_key(s_hunk_inflight, key)
      remove(s_hunk_inflight, key)
    endif
    s_hunk_cache[key] = {failed: true, hunks: []}
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
  InvalidateHunks(bufnr)
  RefreshHunks()
enddef

export def OnBufClose(bufnr: number)
  InvalidateBlame(bufnr)
  InvalidateHunks(bufnr)
enddef

# External git commands (commits, checkouts) invalidate blame and hunks
# silently; a focus regain or shell command is the cheapest signal we get.
# Every visible file buffer refreshes, not only the current one.
export def OnExternalChange()
  if !s_enabled
    return
  endif
  for win in getwininfo()
    if getbufvar(win.bufnr, '&buftype') !=# ''
      continue
    endif
    InvalidateBlame(win.bufnr)
    InvalidateHunks(win.bufnr)
    RequestHunks(win.bufnr, 'signs', false)
  endfor
  ScheduleLineBlame()
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
  # Reuse an existing window for this name instead of stacking splits on
  # every invocation.
  for win in getwininfo()
    if bufname(win.bufnr) ==# name
      win_gotoid(win.winid)
      setlocal modifiable
      silent :%delete _
      if height > 0
        execute 'resize ' .. height
      endif
      return bufnr('%')
    endif
  endfor
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
# Repository-wide commit graph
# =============================================================
def ValidGraphRow(row: any): bool
  return type(row) == v:t_dict
        \ && type(get(row, 'graph', v:null)) == v:t_string
        \ && type(get(row, 'sha', v:null)) == v:t_string
        \ && type(get(row, 'date', v:null)) == v:t_string
        \ && type(get(row, 'author', v:null)) == v:t_string
        \ && type(get(row, 'refs', v:null)) == v:t_string
        \ && type(get(row, 'subject', v:null)) == v:t_string
enddef

def GraphRowDisplay(row: dict<any>): string
  if row.sha ==# ''
    return row.graph
  endif
  var refs = row.refs ==# '' ? '' : '(' .. row.refs .. ') '
  return printf('%s%s %s %-14.14s %s%s',
    row.graph, row.sha, row.date, row.author, refs, row.subject)
enddef

def OnGraphLog(ctx: dict<any>, ev: dict<any>)
  var rows = get(ev, 'rows', v:null)
  if type(rows) != v:t_list
    DebugLog('ignored malformed graph_log response')
    return
  endif
  var path = get(ctx, 'path', '')
  var append_mode = get(ctx, 'append', false)
  var display: list<string> = []
  var shas: list<string> = []
  for row in rows
    if !ValidGraphRow(row)
      continue
    endif
    shas->add(row.sha)
    display->add(GraphRowDisplay(row))
  endfor
  if empty(display) && !append_mode
    Warn('no commits found')
    return
  endif

  if append_mode
    var buf = get(ctx, 'bufnr', -1)
    var win = bufwinid(buf)
    if win == -1
      return
    endif
    if empty(display)
      Warn('no more commits')
      return
    endif
    win_gotoid(win)
    setlocal modifiable
    append(line('$'), display)
    setlocal nomodifiable
    b:simplegit_graph_shas = get(b:, 'simplegit_graph_shas', [])->extend(shas)
    b:simplegit_graph_skip = get(b:, 'simplegit_graph_skip', 0)
      + len(filter(copy(shas), (_, sha) => sha !=# ''))
    return
  endif

  var height = min([max([len(display), 5]), ConfNum('simplegit_log_height', 20)])
  OpenScratch('simplegit://log', height)
  setline(1, display)
  setlocal nomodifiable nowrap
  b:simplegit_graph_shas = shas
  b:simplegit_graph_skip = len(filter(copy(shas), (_, sha) => sha !=# ''))
  b:simplegit_src_path = path

  syntax match SimpleGitLogGraph /^[ |\/\\*_.-]*/
  syntax match SimpleGitLogSha /^[ |\/\\*_.-]*\zs\x\{7,}\ze /
  syntax match SimpleGitBlameDate /\d\{4}-\d\{2}-\d\{2}/
  syntax match SimpleGitLogRefs /([^)]\+)/
  highlight default link SimpleGitLogGraph Comment
  highlight default link SimpleGitLogSha Identifier
  highlight default link SimpleGitLogRefs Special

  nnoremap <silent><buffer> <CR> <ScriptCmd>GraphLogShow()<CR>
  nnoremap <silent><buffer> m <ScriptCmd>GraphLogMore()<CR>
  execute ':1'
enddef

def GraphLogShow()
  var shas = get(b:, 'simplegit_graph_shas', [])
  var path = get(b:, 'simplegit_src_path', '')
  var lnum = line('.')
  if lnum > len(shas) || path ==# ''
    return
  endif
  var sha = shas[lnum - 1]
  if sha ==# ''
    return
  endif
  if !Dispatch({type: 'show', path: path, rev: sha},
      {kind: 'show', interactive: true, title: 'commit ' .. sha})
    Warn('daemon unavailable')
  endif
enddef

def GraphLogMore()
  var path = get(b:, 'simplegit_src_path', '')
  if path ==# ''
    return
  endif
  var limit = ConfNum('simplegit_log_limit', 200)
  var skip = get(b:, 'simplegit_graph_skip', 0)
  if !Dispatch({type: 'graph_log', path: path, limit: limit, skip: skip},
      {kind: 'graph_log', interactive: true, path: path,
       append: true, bufnr: bufnr('%')})
    Warn('daemon unavailable')
  endif
enddef

export def Log()
  var path = BufFilePath(bufnr('%'))
  if path ==# ''
    path = getcwd()
  endif
  var limit = ConfNum('simplegit_log_limit', 200)
  if !Dispatch({type: 'graph_log', path: path, limit: limit, skip: 0},
      {kind: 'graph_log', interactive: true, path: path})
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
# Hunks — signs, navigation, preview, stage and undo
# =============================================================
def SignsEnabled(): bool
  return s_signs_on && ConfBool('simplegit_signs', true) && has('signs')
enddef

def EnsureSignDefs()
  if s_signs_defined
    return
  endif
  sign_define('SimpleGitAdd', {
    text: get(g:, 'simplegit_sign_added', '+'),
    texthl: 'SimpleGitSignAdd',
  })
  sign_define('SimpleGitChange', {
    text: get(g:, 'simplegit_sign_changed', '~'),
    texthl: 'SimpleGitSignChange',
  })
  sign_define('SimpleGitDelete', {
    text: get(g:, 'simplegit_sign_removed', '_'),
    texthl: 'SimpleGitSignDelete',
  })
  s_signs_defined = true
enddef

def ValidHunk(entry: any): bool
  return type(entry) == v:t_dict
        \ && type(get(entry, 'old_start', v:null)) == v:t_number
        \ && type(get(entry, 'old_count', v:null)) == v:t_number
        \ && type(get(entry, 'new_start', v:null)) == v:t_number
        \ && type(get(entry, 'new_count', v:null)) == v:t_number
        \ && type(get(entry, 'lines', v:null)) == v:t_list
enddef

def HunksFor(bufnr: number): list<dict<any>>
  var cached = get(s_hunk_cache, string(bufnr), {})
  if empty(cached) || get(cached, 'failed', false)
    return []
  endif
  return get(cached, 'hunks', [])
enddef

def InvalidateHunks(bufnr: number)
  var key = string(bufnr)
  if has_key(s_hunk_cache, key)
    remove(s_hunk_cache, key)
  endif
  if has_key(s_hunk_stale, key)
    remove(s_hunk_stale, key)
  endif
enddef

# The buffer line a hunk anchors on: its first changed line, or for pure
# deletions the line the change happened after.
def HunkLine(hunk: dict<any>): number
  return max([hunk.new_start, 1])
enddef

def HunkCovers(hunk: dict<any>, lnum: number): bool
  if hunk.new_count == 0
    return lnum == HunkLine(hunk)
  endif
  return lnum >= hunk.new_start && lnum < hunk.new_start + hunk.new_count
enddef

# The sign name wanted on each line, as a dict lnum -> name.
def DesiredSigns(bufnr: number): dict<string>
  var want: dict<string> = {}
  if !SignsEnabled()
    return want
  endif
  var hunks = HunksFor(bufnr)
  if empty(hunks)
    return want
  endif
  var max_signs = ConfNum('simplegit_max_signs', 500)
  var last = get(get(getbufinfo(bufnr), 0, {}), 'linecount', 0)
  var total = 0
  for hunk in hunks
    if hunk.new_count == 0
      want[string(min([HunkLine(hunk), max([last, 1])]))] = 'SimpleGitDelete'
      total += 1
      continue
    endif
    var name = hunk.old_count == 0 ? 'SimpleGitAdd' : 'SimpleGitChange'
    for lnum in range(hunk.new_start, hunk.new_start + hunk.new_count - 1)
      if lnum > last
        break
      endif
      want[string(lnum)] = name
      total += 1
    endfor
  endfor
  if total > max_signs
    DebugLog('not placing ' .. total .. ' signs (over simplegit_max_signs)')
    return {}
  endif
  return want
enddef

# Update signs in place: unplacing everything and starting over makes the
# whole column flicker on every live refresh.
def PlaceSigns(bufnr: number)
  if !bufexists(bufnr) || !has('signs')
    return
  endif
  var want = DesiredSigns(bufnr)
  var priority = ConfNum('simplegit_sign_priority', 10)
  var keep: dict<bool> = {}
  var to_remove: list<dict<any>> = []
  for sign in get(get(sign_getplaced(bufnr, {group: SIGN_GROUP}), 0, {}), 'signs', [])
    var key = string(sign.lnum)
    if get(want, key, '') ==# sign.name && !has_key(keep, key)
      keep[key] = true
    else
      to_remove->add({buffer: bufnr, group: SIGN_GROUP, id: sign.id})
    endif
  endfor
  var to_add: list<dict<any>> = []
  for [key, name] in items(want)
    if !has_key(keep, key)
      to_add->add({buffer: bufnr, group: SIGN_GROUP, priority: priority,
        name: name, lnum: str2nr(key)})
    endif
  endfor
  if !empty(to_remove)
    sign_unplacelist(to_remove)
  endif
  if !empty(to_add)
    EnsureSignDefs()
    sign_placelist(to_add)
  endif
enddef

# Buffer text exactly as it would be written to disk, for the live diff.
def BufferText(bufnr: number): string
  var eol = getbufvar(bufnr, '&endofline') ? 1 : 0
  var ff = getbufvar(bufnr, '&fileformat')
  var sep = ff ==# 'dos' ? "\r\n" : ff ==# 'mac' ? "\r" : "\n"
  return join(getbufline(bufnr, 1, '$'), sep) .. (eol == 1 ? sep : '')
enddef

def RequestHunks(bufnr: number, purpose: string, interactive: bool): bool
  var path = BufFilePath(bufnr)
  if path ==# ''
    return false
  endif
  var key = string(bufnr)
  if has_key(s_hunk_inflight, key)
    # Answer in flight already; rerun once it lands so the last edit wins.
    s_hunk_stale[key] = true
    return true
  endif
  var req: dict<any> = {type: 'hunks', path: path}
  if getbufvar(bufnr, '&modified')
    var text = BufferText(bufnr)
    if len(text) > ConfNum('simplegit_live_max_bytes', 1024 * 1024)
      return false
    endif
    req.content = text
  endif
  var ok = Dispatch(req,
    {kind: 'hunks', bufnr: bufnr, purpose: purpose, interactive: interactive})
  if ok
    s_hunk_inflight[key] = true
  endif
  return ok
enddef

def OnHunks(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var key = string(bufnr)
  if has_key(s_hunk_inflight, key)
    remove(s_hunk_inflight, key)
  endif
  var hunks = get(ev, 'hunks', v:null)
  if type(hunks) != v:t_list
    DebugLog('ignored malformed hunks response')
    return
  endif
  if !bufexists(bufnr)
    return
  endif
  var valid: list<dict<any>> = []
  for entry in hunks
    if ValidHunk(entry)
      valid->add(entry)
    endif
  endfor
  if len(s_hunk_cache) >= 64 && !has_key(s_hunk_cache, key)
    remove(s_hunk_cache, keys(s_hunk_cache)[0])
  endif
  s_hunk_cache[key] = {failed: false, hunks: valid}
  PlaceSigns(bufnr)
  var purpose = get(ctx, 'purpose', 'signs')
  if purpose ==# 'preview'
    ShowHunkPreview(bufnr)
  elseif purpose ==# 'next'
    JumpHunk(bufnr, 1)
  elseif purpose ==# 'prev'
    JumpHunk(bufnr, -1)
  endif
  if has_key(s_hunk_stale, key)
    remove(s_hunk_stale, key)
    RequestHunks(bufnr, 'signs', false)
  endif
enddef

def OnHunkOp(ctx: dict<any>, ev: dict<any>)
  var bufnr = get(ctx, 'bufnr', -1)
  var action = get(ev, 'action', '')
  if !bufexists(bufnr)
    return
  endif
  if action ==# 'undo'
    # The daemon rewrote the file on disk; pick the change up. A plain
    # checktime only reloads with 'autoread', so re-edit when it is safe.
    if bufnr == bufnr('%') && !getbufvar(bufnr, '&modified')
      var view = winsaveview()
      silent! execute 'edit!'
      winrestview(view)
    else
      silent! execute 'checktime ' .. bufnr
    endif
    InvalidateBlame(bufnr)
    ScheduleLineBlame()
  endif
  InvalidateHunks(bufnr)
  RequestHunks(bufnr, 'signs', false)
  echo '[SimpleGit] ' .. (action ==# 'undo' ? 'hunk reverted' : 'hunk staged')
enddef

def JumpHunk(bufnr: number, direction: number)
  if bufnr != bufnr('%')
    return
  endif
  var hunks = HunksFor(bufnr)
  if empty(hunks)
    Warn('no hunks in this buffer')
    return
  endif
  var lnum = line('.')
  var target = 0
  if direction > 0
    for hunk in hunks
      if HunkLine(hunk) > lnum
        target = HunkLine(hunk)
        break
      endif
    endfor
  else
    for hunk in reverse(copy(hunks))
      if HunkLine(hunk) < lnum
        target = HunkLine(hunk)
        break
      endif
    endfor
  endif
  if target == 0
    Warn(direction > 0 ? 'no next hunk' : 'no previous hunk')
    return
  endif
  normal! m'
  cursor(target, 1)
enddef

def ShowHunkPreview(bufnr: number)
  if bufnr != bufnr('%')
    return
  endif
  var lnum = line('.')
  for hunk in HunksFor(bufnr)
    if !HunkCovers(hunk, lnum)
      continue
    endif
    if has('popupwin')
      var winid = popup_atcursor(hunk.lines, {
        padding: [0, 1, 0, 1],
        border: [1, 1, 1, 1],
        borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        moved: 'any',
        maxheight: 20,
      })
      win_execute(winid, 'setlocal filetype=diff')
    else
      echo join(hunk.lines, "\n")
    endif
    return
  endfor
  Warn('no hunk under cursor')
enddef

# Shared entry guard: hunk features need a readable, unmodified file.
def HunkTarget(need_saved: bool): number
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    Warn('current buffer has no readable file')
    return -1
  endif
  if need_saved && getbufvar(bufnr, '&modified')
    Warn('save the buffer first; hunks reflect the file on disk')
    return -1
  endif
  return bufnr
enddef

export def HunkNext()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'next', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  JumpHunk(bufnr, 1)
enddef

export def HunkPrev()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'prev', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  JumpHunk(bufnr, -1)
enddef

export def HunkPreview()
  var bufnr = HunkTarget(false)
  if bufnr < 0
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    if !RequestHunks(bufnr, 'preview', true)
      Warn('daemon unavailable; run ./install.sh')
    endif
    return
  endif
  ShowHunkPreview(bufnr)
enddef

def HunkOperate(op: string)
  var bufnr = HunkTarget(true)
  if bufnr < 0
    return
  endif
  var hunks = HunksFor(bufnr)
  if !empty(get(s_hunk_cache, string(bufnr), {})) && empty(hunks)
    Warn('no hunks in this buffer')
    return
  endif
  if !Dispatch({type: op, path: BufFilePath(bufnr), lnum: line('.')},
      {kind: 'hunk_op', bufnr: bufnr, interactive: true})
    Warn('daemon unavailable; run ./install.sh')
  endif
enddef

export def HunkStage()
  HunkOperate('stage')
enddef

export def HunkUndo()
  HunkOperate('undo')
enddef

export def RefreshHunks()
  if !s_enabled || !SignsEnabled()
    return
  endif
  var bufnr = bufnr('%')
  if BufFilePath(bufnr) ==# ''
    return
  endif
  if empty(get(s_hunk_cache, string(bufnr), {}))
    RequestHunks(bufnr, 'signs', false)
  else
    PlaceSigns(bufnr)
  endif
enddef

# Debounced follow-up while typing: diff the unsaved buffer so the signs
# track the edit instead of the file on disk.
export def ScheduleHunks()
  if !s_enabled || !SignsEnabled() || !has('timers')
    return
  endif
  if s_hunk_timer != 0
    timer_stop(s_hunk_timer)
  endif
  s_hunk_timer = timer_start(ConfNum('simplegit_hunk_delay', 300), (_) => {
    s_hunk_timer = 0
    var bufnr = bufnr('%')
    if get(get(s_hunk_cache, string(bufnr), {}), 'failed', false)
      # Outside a repository or untracked; do not hammer the daemon per edit.
      return
    endif
    RequestHunks(bufnr, 'signs', false)
  })
enddef

export def ToggleSigns()
  s_signs_on = !s_signs_on
  if s_signs_on
    RefreshHunks()
    echo '[SimpleGit] signs on'
  else
    if has('signs')
      sign_unplace(SIGN_GROUP)
    endif
    echo '[SimpleGit] signs off'
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
  nnoremap <silent><buffer> a <ScriptCmd>StatusFileOp('add')<CR>
  nnoremap <silent><buffer> u <ScriptCmd>StatusFileOp('reset')<CR>
  nnoremap <silent><buffer> R <ScriptCmd>StatusRefresh()<CR>
  nnoremap <silent><buffer> c <ScriptCmd>Commit(false)<CR>
  nnoremap <silent><buffer> C <ScriptCmd>Commit(true)<CR>
  execute ':' .. min([max([get(ctx, 'lnum', 1), 1]), line('$')])
enddef

def StatusRefresh(lnum: number = 0)
  var dir = get(b:, 'simplegit_dir', getcwd())
  if !Dispatch({type: 'status', path: dir},
      {kind: 'status', interactive: true, dir: dir,
       lnum: lnum > 0 ? lnum : line('.')})
    Warn('daemon unavailable')
  endif
enddef

def StatusFileOp(op: string)
  var paths = get(b:, 'simplegit_paths', [])
  var dir = get(b:, 'simplegit_dir', getcwd())
  var lnum = line('.')
  if lnum > len(paths) || paths[lnum - 1] ==# ''
    return
  endif
  if !Dispatch({type: 'file_op', path: dir, op: op, file: paths[lnum - 1]},
      {kind: 'file_op', interactive: true, dir: dir, lnum: lnum})
    Warn('daemon unavailable')
  endif
enddef

# =============================================================
# Commit
#
# The message is composed in a scratch buffer and sent over the daemon's stdin,
# so it may contain anything -- newlines, quotes, non-ASCII -- without shell
# quoting. Comment lines are stripped by `git commit --cleanup=strip`, matching
# what git's own editor flow does.
# =============================================================

const COMMIT_BUF = 'simplegit://commit'

# Which repository a commit belongs to.  The scratch windows this plugin opens
# (status, commit) have no file name, so expand('%:p:h') on them is not a
# directory and would silently fall through to getcwd() -- committing in
# whatever repository Vim happens to be started in rather than the one the
# status view is showing.  Those buffers record their own directory, so prefer
# it; :SimpleGitCommit bound to `c` in the status window depends on this.
def CommitRepoDir(): string
  var owned = get(b:, 'simplegit_dir', '')
  if type(owned) == v:t_string && owned !=# '' && isdirectory(owned)
    return owned
  endif
  var dir = expand('%:p:h')
  if dir ==# '' || !isdirectory(dir)
    dir = getcwd()
  endif
  return dir
enddef

def CommitHelpLines(dir: string, amend: bool): list<string>
  var lines = [
    '',
    '# Write the commit message above, then :w to commit or :q to abort.',
    '#',
    '# Lines starting with # are ignored.',
  ]
  if amend
    lines->add('# This REWRITES the previous commit (git commit --amend).')
  endif
  lines->add('#')
  return lines
enddef

export def Commit(amend: bool = false)
  var dir = CommitRepoDir()
  if !StartDaemon()
    Warn('daemon unavailable; run ./install.sh')
    return
  endif

  OpenScratch(COMMIT_BUF, 12)
  setlocal buftype=acwrite modifiable
  setlocal filetype=gitcommit

  var body = CommitHelpLines(dir, amend)
  # Amending starts from the existing message so it can be edited rather than
  # retyped; it is fetched asynchronously and prepended when it arrives.
  setline(1, body)
  b:simplegit_dir = dir
  b:simplegit_amend = amend
  normal! gg

  # :w commits. This is the muscle memory from git's own editor, and it keeps
  # the buffer from ever being written to disk.
  augroup SimpleGitCommitBuf
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> CommitFinish()
  augroup END
  nnoremap <silent><buffer> q <Cmd>call <SID>CommitAbort()<CR>

  if amend
    # Fetched asynchronously and prepended when it arrives, so amending edits
    # the existing message instead of silently replacing it.
    Dispatch({type: 'commit_message', path: dir},
      {kind: 'commit_message', interactive: false, dir: dir})
  endif
  startinsert
enddef

def CommitAbort()
  setlocal nomodified
  close
  echo '[SimpleGit] commit aborted'
enddef

def CommitFinish()
  var dir = get(b:, 'simplegit_dir', getcwd())
  var amend = get(b:, 'simplegit_amend', false)
  var message: list<string> = []
  for line in getline(1, '$')
    if line !~# '^#'
      message->add(line)
    endif
  endfor
  var text = trim(join(message, "\n"))
  if text ==# ''
    Warn('empty commit message; nothing committed')
    return
  endif
  setlocal nomodified
  # Force a real boolean: the command passes <bang>0, which is a number, and
  # json_encode() would put 0 on the wire where the daemon expects false.
  if !Dispatch({type: 'commit', path: dir, message: text, amend: amend ? true : false},
      {kind: 'commit', interactive: true, dir: dir})
    Warn('daemon unavailable')
  endif
enddef

def OnCommitMessage(ctx: dict<any>, ev: dict<any>)
  var lines = get(ev, 'lines', [])
  if type(lines) != v:t_list || empty(lines)
    return
  endif
  # The buffer may have been closed, or the user may already have started
  # typing; in either case leave what is there alone.
  var bufnr = bufnr(COMMIT_BUF)
  if bufnr <= 0 || !bufexists(bufnr)
    return
  endif
  var existing = getbufline(bufnr, 1, '$')
  var typed = filter(copy(existing), (_, l) => l !~# '^#' && trim(l) !=# '')
  if !empty(typed)
    return
  endif
  var body: list<string> = []
  for l in lines
    body->add(type(l) == v:t_string ? l : string(l))
  endfor
  setbufline(bufnr, 1, body + existing)
enddef

def OnCommit(ctx: dict<any>, ev: dict<any>)
  var sha = get(ev, 'sha', '')
  var subject = get(ev, 'subject', '')
  # Close the message buffer only once git has actually accepted the commit,
  # so a rejected message is never lost.
  for win in getwininfo()
    if bufname(win.bufnr) ==# COMMIT_BUF
      win_gotoid(win.winid)
      setlocal nomodified
      close
      break
    endif
  endfor
  OnExternalChange()
  echo printf('[SimpleGit] committed %s %s', sha, subject)
  var dir = get(ctx, 'dir', '')
  if dir !=# ''
    Dispatch({type: 'status', path: dir},
      {kind: 'status', interactive: false, dir: dir, lnum: 1})
  endif
enddef

def OnFileOp(ctx: dict<any>, ev: dict<any>)
  # The index changed under every buffer of this repository; refresh what is
  # visible, then re-render the status window it was triggered from.
  OnExternalChange()
  var dir = get(ctx, 'dir', '')
  if dir ==# ''
    return
  endif
  Dispatch({type: 'status', path: dir},
    {kind: 'status', interactive: false, dir: dir, lnum: get(ctx, 'lnum', 1)})
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
  s_signs_on = ConfBool('simplegit_signs', true)
  # Manual enable is the escape hatch after repeated daemon failures.
  SetupCore()
  simplegit#core#ClearBreaker()
  StartDaemon()
  ScheduleLineBlame()
  RefreshHunks()
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
  if s_hunk_timer != 0
    timer_stop(s_hunk_timer)
    s_hunk_timer = 0
  endif
  ClearLineBlame(bufnr('%'))
  if has('signs')
    sign_unplace(SIGN_GROUP)
  endif
  Stop()
enddef

export def Stop()
  SetupCore()
  simplegit#core#Stop()
  s_daemon_ready = false
  ClearPending()
  s_blame_cache = {}
  s_hunk_cache = {}
enddef

export def Restart()
  SetupCore()
  s_daemon_ready = false
  s_daemon_incompatible = false
  ClearPending()
  if simplegit#core#Restart()
    echom '[SimpleGit] daemon restarted'
  endif
enddef

export def ShowLog()
  simplegit#core#ShowLog()
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def Health()
  SetupCore()
  var h = simplegit#core#Health()
  echo '[SimpleGit] health'
  echo '  enabled:        ' .. (s_enabled ? 'yes' : 'no')
  echo '  daemon binary:  ' .. (h.exe_path ==# '' ? '(not found — run ./install.sh)' : h.exe_path)
  echo '  daemon running: ' .. (h.running ? 'yes' : 'no')
  echo '  daemon version: ' .. (s_daemon_version ==# '' ? 'unknown' : s_daemon_version)
        .. '/' .. s_daemon_protocol
        .. (s_daemon_incompatible ? ' (INCOMPATIBLE — rerun ./install.sh)' : '')
  echo '  virtual text:   ' .. (VirtualTextSupported() ? 'supported' : 'unsupported (needs Vim 9.0.0067+)')
  echo '  popups:         ' .. (has('popupwin') ? 'supported' : 'unsupported')
  echo '  line blame:     ' .. (s_line_blame_on ? 'on' : 'off')
  echo '  hunk signs:     ' .. (SignsEnabled() ? 'on' : 'off')
  echo '  live diff:      up to ' .. ConfNum('simplegit_live_max_bytes', 1024 * 1024) .. ' bytes, '
        .. ConfNum('simplegit_hunk_delay', 300) .. 'ms debounce'
  echo '  cached buffers: ' .. len(s_blame_cache) .. ' blame, ' .. len(s_hunk_cache) .. ' hunks'
  echo '  pending:        ' .. len(s_pending)
  echo '  crashes:        ' .. h.crashes .. ' (restarts: ' .. h.restarts .. ')'
        .. (h.breaker_open ? ' — auto-restart disabled, run :SimpleGitRestart' : '')
  echo '  last message:   ' .. (s_last_error ==# '' ? '(none)' : s_last_error)
enddef

export def DebugStatus()
  Health()
enddef

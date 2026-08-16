vim9script

if exists('g:loaded_simplegit')
  finish
endif
g:loaded_simplegit = 1
# Keep in step with `version` in Cargo.toml; tests/vim_smoke.vim fails the
# build when the two disagree, because this is the number a user quotes.
g:simplegit_version = '0.5.0'

def ConfigFlag(name: string, default_value: number): number
  var value = get(g:, name, default_value)
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  if type(value) == v:t_number
    return value != 0 ? 1 : 0
  endif
  return default_value
enddef

# =============================================================
# Configuration
# =============================================================
g:simplegit_debug = ConfigFlag('simplegit_debug', 0)
g:simplegit_daemon_path = get(g:, 'simplegit_daemon_path', '')
g:simplegit_auto_enable = ConfigFlag('simplegit_auto_enable', 1)
# GitLens-style current-line blame annotation (virtual text).
g:simplegit_line_blame = ConfigFlag('simplegit_line_blame', 1)
# Delay (ms) after the cursor stops before the annotation appears.
g:simplegit_blame_delay = get(g:, 'simplegit_blame_delay', 350)
# Annotation layout: %a author, %e email, %h short sha, %d date, %w relative
# time, %s summary, %% a literal percent.
g:simplegit_blame_format = get(g:, 'simplegit_blame_format', '%a, %w • %s')
# Width of the :SimpleGitBlame sidebar.
g:simplegit_blame_width = get(g:, 'simplegit_blame_width', 34)
# Maximum commits shown by :SimpleGitHistory.
g:simplegit_history_limit = get(g:, 'simplegit_history_limit', 200)
g:simplegit_history_height = get(g:, 'simplegit_history_height', 15)
# Hunk signs in the sign column (working tree vs index).
g:simplegit_signs = ConfigFlag('simplegit_signs', 1)
g:simplegit_sign_added = get(g:, 'simplegit_sign_added', '+')
g:simplegit_sign_changed = get(g:, 'simplegit_sign_changed', '~')
g:simplegit_sign_removed = get(g:, 'simplegit_sign_removed', '_')
g:simplegit_sign_priority = get(g:, 'simplegit_sign_priority', 10)
# Above this many signs in one buffer none are placed.
g:simplegit_max_signs = get(g:, 'simplegit_max_signs', 500)
# Debounce (ms) for the live buffer-vs-index diff while typing.
g:simplegit_hunk_delay = get(g:, 'simplegit_hunk_delay', 300)
# Debounce status refreshes triggered by FocusGained/ShellCmdPost.
g:simplegit_status_auto_refresh = ConfigFlag('simplegit_status_auto_refresh', 1)
g:simplegit_status_refresh_delay = get(g:, 'simplegit_status_refresh_delay', 150)
# Buffers above this size fall back to the on-disk diff.
g:simplegit_live_max_bytes = get(g:, 'simplegit_live_max_bytes', 1024 * 1024)
# Let the daemon watch each repository and push the changes made outside Vim
# (a checkout in another terminal) instead of waiting for FocusGained.
g:simplegit_watch = ConfigFlag('simplegit_watch', 1)
g:simplegit_watch_interval = get(g:, 'simplegit_watch_interval', 2000)
# SimpleRemote workspaces: which buffers run git on the workspace host.
#   'auto'   remote:// buffers (they have no local file)   -- default
#   'always' also projected buffers (b:simpleremote_path) instead of local git
#            over the sshfs / bind mount
#   'never'  none (remote:// buffers then have no git at all)
g:simplegit_remote_git = get(g:, 'simplegit_remote_git', 'auto')
# Debounces for remote buffers: each request is a round trip to the host.
g:simplegit_remote_blame_delay = get(g:, 'simplegit_remote_blame_delay', 750)
g:simplegit_remote_hunk_delay = get(g:, 'simplegit_remote_hunk_delay', 750)
g:simplegit_enable_default_mappings = ConfigFlag('simplegit_enable_default_mappings', 1)

# =============================================================
# Highlights
# =============================================================
highlight default link SimpleGitBlameVirtual NonText
highlight default link SimpleGitBlameSha Identifier
highlight default link SimpleGitBlameDate Comment
highlight default link SimpleGitBlameUncommitted Comment
highlight default link SimpleGitStatusBranch Title
highlight default link SimpleGitStatusUntracked Comment
highlight default link SimpleGitStatusConflict Error
highlight default link SimpleGitSignAdd Added
highlight default link SimpleGitSignChange Changed
highlight default link SimpleGitSignDelete Removed

# =============================================================
# Commands
# =============================================================
command! SimpleGitEnable simplegit#Enable()
command! SimpleGitDisable simplegit#Disable()
command! SimpleGitToggle simplegit#Toggle()
command! SimpleGitHealth simplegit#Health()
command! SimpleGitBlame simplegit#ToggleBlame()
command! SimpleGitBlameLine simplegit#BlameLine()
command! SimpleGitToggleLineBlame simplegit#ToggleLineBlame()
command! SimpleGitHistory simplegit#History()
command! SimpleGitLog simplegit#Log()
command! SimpleGitStatus simplegit#Status()
command! SimpleGitStageAll simplegit#StageAll()
command! SimpleGitUnstageAll simplegit#UnstageAll()
command! -nargs=? SimpleGitDiff simplegit#Diff(<q-args>)
command! -nargs=? SimpleGitShow simplegit#Show(<q-args>)
command! SimpleGitHunkNext simplegit#HunkNext()
command! SimpleGitHunkPrev simplegit#HunkPrev()
# -range: with no range Vim passes the cursor line as both ends, so the
# rangeless forms keep meaning exactly what they always did.
command! -range SimpleGitHunkPreview simplegit#HunkPreview(<line1>, <line2>)
command! -range SimpleGitHunkStage simplegit#HunkStage(<line1>, <line2>)
command! -range SimpleGitHunkUndo simplegit#HunkUndo(<line1>, <line2>)
command! SimpleGitToggleSigns simplegit#ToggleSigns()
command! -bang SimpleGitCommit simplegit#Commit(<bang>0)
command! SimpleGitRestart simplegit#Restart()
command! SimpleGitDaemonLog simplegit#ShowLog()

# =============================================================
# Mappings
# =============================================================
nnoremap <silent> <Plug>(simplegit-blame) <Cmd>SimpleGitBlame<CR>
nnoremap <silent> <Plug>(simplegit-blame-line) <Cmd>SimpleGitBlameLine<CR>
nnoremap <silent> <Plug>(simplegit-history) <Cmd>SimpleGitHistory<CR>
nnoremap <silent> <Plug>(simplegit-log) <Cmd>SimpleGitLog<CR>
nnoremap <silent> <Plug>(simplegit-diff) <Cmd>SimpleGitDiff<CR>
nnoremap <silent> <Plug>(simplegit-status) <Cmd>SimpleGitStatus<CR>
nnoremap <silent> <Plug>(simplegit-stage-all) <Cmd>SimpleGitStageAll<CR>
nnoremap <silent> <Plug>(simplegit-unstage-all) <Cmd>SimpleGitUnstageAll<CR>
nnoremap <silent> <Plug>(simplegit-toggle-line-blame) <Cmd>SimpleGitToggleLineBlame<CR>
nnoremap <silent> <Plug>(simplegit-hunk-next) <Cmd>SimpleGitHunkNext<CR>
nnoremap <silent> <Plug>(simplegit-hunk-prev) <Cmd>SimpleGitHunkPrev<CR>
nnoremap <silent> <Plug>(simplegit-hunk-preview) <Cmd>SimpleGitHunkPreview<CR>
nnoremap <silent> <Plug>(simplegit-hunk-stage) <Cmd>SimpleGitHunkStage<CR>
nnoremap <silent> <Plug>(simplegit-hunk-undo) <Cmd>SimpleGitHunkUndo<CR>

# Visual mode: operate on every hunk the selection touches.  ':' in visual mode
# inserts the '<,'> range, which the -range commands pass straight through.
xnoremap <silent> <Plug>(simplegit-hunk-stage) :SimpleGitHunkStage<CR>
xnoremap <silent> <Plug>(simplegit-hunk-undo) :SimpleGitHunkUndo<CR>
xnoremap <silent> <Plug>(simplegit-hunk-preview) :SimpleGitHunkPreview<CR>

# Hunk text objects.  ':<C-u>' rather than '<Cmd>': the function reselects
# linewise, which a <Cmd> mapping is not allowed to do.
onoremap <silent> <Plug>(simplegit-hunk-inner) :<C-u>call simplegit#SelectHunk(v:false)<CR>
xnoremap <silent> <Plug>(simplegit-hunk-inner) :<C-u>call simplegit#SelectHunk(v:false)<CR>
onoremap <silent> <Plug>(simplegit-hunk-around) :<C-u>call simplegit#SelectHunk(v:true)<CR>
xnoremap <silent> <Plug>(simplegit-hunk-around) :<C-u>call simplegit#SelectHunk(v:true)<CR>

# Defaults never replace a mapping owned by the user.
if g:simplegit_enable_default_mappings
  if maparg('<leader>gb', 'n') ==# ''
    nmap <silent> <leader>gb <Plug>(simplegit-blame)
  endif
  if maparg('<leader>gm', 'n') ==# ''
    nmap <silent> <leader>gm <Plug>(simplegit-blame-line)
  endif
  if maparg('<leader>gh', 'n') ==# ''
    nmap <silent> <leader>gh <Plug>(simplegit-history)
  endif
  if maparg('<leader>gl', 'n') ==# ''
    nmap <silent> <leader>gl <Plug>(simplegit-log)
  endif
  if maparg('<leader>gd', 'n') ==# ''
    nmap <silent> <leader>gd <Plug>(simplegit-diff)
  endif
  if maparg('<leader>gs', 'n') ==# ''
    nmap <silent> <leader>gs <Plug>(simplegit-status)
  endif
  if maparg(']g', 'n') ==# ''
    nmap <silent> ]g <Plug>(simplegit-hunk-next)
  endif
  if maparg('[g', 'n') ==# ''
    nmap <silent> [g <Plug>(simplegit-hunk-prev)
  endif
  if maparg('<leader>gp', 'n') ==# ''
    nmap <silent> <leader>gp <Plug>(simplegit-hunk-preview)
  endif
  if maparg('<leader>ga', 'n') ==# ''
    nmap <silent> <leader>ga <Plug>(simplegit-hunk-stage)
  endif
  if maparg('<leader>gu', 'n') ==# ''
    nmap <silent> <leader>gu <Plug>(simplegit-hunk-undo)
  endif
  # The same three leaders in visual mode, applied to the selection.
  if maparg('<leader>ga', 'x') ==# ''
    xmap <silent> <leader>ga <Plug>(simplegit-hunk-stage)
  endif
  if maparg('<leader>gu', 'x') ==# ''
    xmap <silent> <leader>gu <Plug>(simplegit-hunk-undo)
  endif
  if maparg('<leader>gp', 'x') ==# ''
    xmap <silent> <leader>gp <Plug>(simplegit-hunk-preview)
  endif
  # 'h' for hunk, matching gitgutter's ic/ac and gitsigns' ih.
  if maparg('ih', 'o') ==# ''
    omap <silent> ih <Plug>(simplegit-hunk-inner)
  endif
  if maparg('ih', 'x') ==# ''
    xmap <silent> ih <Plug>(simplegit-hunk-inner)
  endif
  if maparg('ah', 'o') ==# ''
    omap <silent> ah <Plug>(simplegit-hunk-around)
  endif
  if maparg('ah', 'x') ==# ''
    xmap <silent> ah <Plug>(simplegit-hunk-around)
  endif
endif

# =============================================================
# Auto-enable and blame refresh
# =============================================================
augroup SimpleGit
  autocmd!
  if g:simplegit_auto_enable
    autocmd VimEnter * ++once simplegit#Enable()
  endif
  autocmd CursorMoved,BufEnter * simplegit#ScheduleLineBlame()
  autocmd InsertLeave * simplegit#ScheduleLineBlame()
  autocmd BufWritePost * simplegit#OnBufWrite()
  # BufReadPost also fires on a re-read of a buffer that is already open, so it
  # says "this text was replaced"; BufEnter only says "you are looking at it".
  autocmd BufReadPost * simplegit#RefreshHunks(true)
  autocmd BufEnter * simplegit#RefreshHunks()
  autocmd TextChanged,TextChangedI,TextChangedP * simplegit#ScheduleHunks()
  autocmd FocusGained,ShellCmdPost * simplegit#OnExternalChange()
  autocmd BufDelete * simplegit#OnBufClose(expand('<abuf>')->str2nr())
  autocmd VimLeavePre * try | simplegit#Stop() | catch | endtry
  # SimpleRemote workspaces.  Harmless without SimpleRemote: nothing fires
  # them.  A remote:// buffer is filled by a BufReadCmd, so BufReadPost never
  # fires for it and SimpleRemoteBufferRead is its "read" instead; the
  # connection events invalidate what was cached for the previous host; the
  # files-changed event stands in for the repository watch, which cannot see a
  # remote git directory.
  autocmd User SimpleRemoteBufferRead simplegit#OnRemoteBufferRead()
  autocmd User SimpleRemoteConnected,SimpleRemoteWorkspaceChanged,SimpleRemoteDisconnected
        \ simplegit#OnRemoteWorkspace()
  autocmd User SimpleRemoteFilesChanged simplegit#OnRemoteFilesChanged()
augroup END

if g:simplegit_auto_enable && v:vim_did_enter
  simplegit#Enable()
endif

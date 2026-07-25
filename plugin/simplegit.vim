vim9script

if exists('g:loaded_simplegit')
  finish
endif
g:loaded_simplegit = 1
g:simplegit_version = '0.3.0'

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
# Buffers above this size fall back to the on-disk diff.
g:simplegit_live_max_bytes = get(g:, 'simplegit_live_max_bytes', 1024 * 1024)
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
command! -nargs=? SimpleGitDiff simplegit#Diff(<q-args>)
command! -nargs=? SimpleGitShow simplegit#Show(<q-args>)
command! SimpleGitHunkNext simplegit#HunkNext()
command! SimpleGitHunkPrev simplegit#HunkPrev()
command! SimpleGitHunkPreview simplegit#HunkPreview()
command! SimpleGitHunkStage simplegit#HunkStage()
command! SimpleGitHunkUndo simplegit#HunkUndo()
command! SimpleGitToggleSigns simplegit#ToggleSigns()

# =============================================================
# Mappings
# =============================================================
nnoremap <silent> <Plug>(simplegit-blame) <Cmd>SimpleGitBlame<CR>
nnoremap <silent> <Plug>(simplegit-blame-line) <Cmd>SimpleGitBlameLine<CR>
nnoremap <silent> <Plug>(simplegit-history) <Cmd>SimpleGitHistory<CR>
nnoremap <silent> <Plug>(simplegit-log) <Cmd>SimpleGitLog<CR>
nnoremap <silent> <Plug>(simplegit-diff) <Cmd>SimpleGitDiff<CR>
nnoremap <silent> <Plug>(simplegit-status) <Cmd>SimpleGitStatus<CR>
nnoremap <silent> <Plug>(simplegit-toggle-line-blame) <Cmd>SimpleGitToggleLineBlame<CR>
nnoremap <silent> <Plug>(simplegit-hunk-next) <Cmd>SimpleGitHunkNext<CR>
nnoremap <silent> <Plug>(simplegit-hunk-prev) <Cmd>SimpleGitHunkPrev<CR>
nnoremap <silent> <Plug>(simplegit-hunk-preview) <Cmd>SimpleGitHunkPreview<CR>
nnoremap <silent> <Plug>(simplegit-hunk-stage) <Cmd>SimpleGitHunkStage<CR>
nnoremap <silent> <Plug>(simplegit-hunk-undo) <Cmd>SimpleGitHunkUndo<CR>

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
  autocmd BufReadPost,BufEnter * simplegit#RefreshHunks()
  autocmd TextChanged,TextChangedI,TextChangedP * simplegit#ScheduleHunks()
  autocmd FocusGained,ShellCmdPost * simplegit#OnExternalChange()
  autocmd BufDelete * simplegit#OnBufClose(expand('<abuf>')->str2nr())
  autocmd VimLeavePre * try | simplegit#Stop() | catch | endtry
augroup END

if g:simplegit_auto_enable && v:vim_did_enter
  simplegit#Enable()
endif

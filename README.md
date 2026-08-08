# Simplegit

Simplegit brings GitLens-style Git insight to Vim 9: an inline current-line blame annotation, a whole-file blame sidebar, file history, diff against any revision, commit inspection, a repository status window, and hunk handling: sign-column change markers with navigation, preview, stage and undo.

Like the other `simple*` plugins, rendering stays in Vim9script and all git work runs in a small asynchronous Rust daemon over a JSON line protocol — editing never waits on `git`.

## Features

- **Inline line blame** (GitLens style): `author, 3 days ago • commit summary` appears as virtual text after the current line, debounced and only when the buffer is unmodified. One line is blamed at a time (`git blame -L`) and cached per line, so deep history costs nothing extra; the layout is `g:simplegit_blame_format`.
- **Blame sidebar** (`:SimpleGitBlame`): per-line commit/date/author, scroll-synced with the file; `<CR>` opens the commit, `p` pops up its details, `q` closes.
- **File history** (`:SimpleGitHistory`): `git log --follow` for the current file; `<CR>` shows the commit's changes to this file, `a` the whole commit.
- **Commit graph** (`:SimpleGitLog`): repository-wide `git log --graph` with branch topology, refs and dates; `<CR>` shows the commit under the cursor, `m` loads more commits.
- **Diff against a revision** (`:SimpleGitDiff [rev]`): vertical `diffthis` split of the working file against HEAD or any revision.
- **Commit inspection** (`:SimpleGitShow [rev]`): message, stats and patch with `git` syntax highlighting.
- **Repository status** (`:SimpleGitStatus`): branch plus changed files; `<CR>` opens a file, `d` opens and diffs it, `a`/`u` stage/unstage it, `A`/`U` stage/unstage the whole repository, `R` refreshes.
- **Line blame popup** (`:SimpleGitBlameLine`): commit, author, date, and summary for the line under the cursor.
- **Hunk handling** (GitGutter style): `+`/`~`/`_` signs for changes against the index — updated live while you type, without saving — plus hunk navigation (`:SimpleGitHunkNext`/`Prev`), a diff preview popup, and per-hunk stage (`:SimpleGitHunkStage`) and undo (`:SimpleGitHunkUndo`).
- **Statusline API**: `simplegit#StatusLine()` renders `main ↑2 ↓1 +12 ~3 -1`; `simplegit#StatusDict()`, `simplegit#Head()` and `simplegit#HunkSummary()` expose the same data, and every file buffer carries `b:simplegit_status_dict`. All of it reads caches the plugin already keeps, so it is safe on the redraw path — no statusline plugin needs to run its own `git`.
- Asynchronous daemon with a version/capability handshake, request correlation, concurrency limiting and timeouts; index-changing requests run through a FIFO lane, while UI replies are tied to their initiating tab/window/repository and never pull focus back after you move on. `:SimpleGitHealth` exposes the negotiated support.

## Requirements

- Vim 9.1 with `+vim9script`, `+job`, `+channel`.
- Virtual text (patch 9.0.0067+) for the inline annotation; `+popupwin` for popups; `+timers` for debouncing. Everything else degrades gracefully.
- Git, and Rust/Cargo 1.88 or newer to build the daemon.

Simplegit is Vim9-only. Neovim does not implement Vim9script or Vim's job/channel API, so it is not supported by this plugin.

## Installation

With vim-plug:

```vim
Plug 'beamiter/simplegit', {'do': './install.sh'}
```

Or clone/update the plugin and run:

```sh
./install.sh
```

The installer performs a locked release build, atomically installs `lib/simplegit-daemon`, and generates Vim help tags when `vim` is on `PATH`. Rerun it after every source update.

## Usage

| Command | Action |
| --- | --- |
| `:SimpleGitBlame` | Toggle the blame sidebar |
| `:SimpleGitBlameLine` | Popup blame for the current line |
| `:SimpleGitHistory` | File history window |
| `:SimpleGitLog` | Repository commit graph |
| `:SimpleGitDiff [rev]` | Diff file against `rev` (default `HEAD`) |
| `:SimpleGitShow [rev]` | Show a commit |
| `:SimpleGitStatus` | Repository status window |
| `:SimpleGitStageAll` / `:SimpleGitUnstageAll` | Stage / unstage the whole repository |
| `:SimpleGitToggleLineBlame` | Toggle the inline annotation |
| `:SimpleGitHunkNext` / `:SimpleGitHunkPrev` | Jump to the next/previous hunk |
| `:SimpleGitHunkPreview` | Popup diff of the hunk under the cursor |
| `:SimpleGitHunkStage` | Stage the hunk under the cursor |
| `:SimpleGitHunkUndo` | Revert the hunk under the cursor |
| `:SimpleGitToggleSigns` | Toggle the sign-column markers |
| `:SimpleGitHealth` | Diagnostics |

### Statusline

```vim
set statusline+=%{simplegit#StatusLine()}
autocmd User SimpleGitUpdate redrawstatus!
```

`simplegit#StatusLine()` returns `main ↑2 ↓1 +12 ~3 -1` — upstream distance
plus added/changed/removed lines in the current buffer — and an empty string
while the branch is unknown or the buffer is outside a repository, so it can be
concatenated unconditionally. `simplegit#StatusDict([bufnr])` returns the same
as `{'head', 'ahead', 'behind', 'added', 'changed', 'removed'}`, mirrored on
every file buffer as `b:simplegit_status_dict`. `User SimpleGitUpdate` fires
when that dict changes, and only when something is listening. None of these
accessors dispatches a request or blocks; the branch is read once per
repository from the buffer lifecycle instead. See `:help simplegit-statusline`.

Whole-repository stage/unstage is an additive protocol-5 capability. If Vim
finds an older protocol-5 daemon, these two commands fail closed with an
upgrade message instead of sending an operation the daemon may misinterpret;
the rest of Simplegit continues to work. Rerun `./install.sh` after updating.

Status is latest-request-wins, including the first asynchronous open. A
commit message is likewise generation-guarded: a second `:write` is refused
while the commit is pending, and text typed after the first `:write` is kept
open for a deliberate follow-up instead of being discarded by the reply.
While a status view is open, `FocusGained` and `ShellCmdPost` refresh it
automatically after a 150 ms debounce. Bursts coalesce, only the existing
window/repository is updated, and an asynchronous reply never changes the
current tab, window, or buffer. Set `g:simplegit_status_auto_refresh = 0` to
disable Focus/Shell-driven refreshes, or tune the debounce with
`g:simplegit_status_refresh_delay`; `R` remains an immediate manual refresh.
Explicit status opens and in-place refreshes share one buffer generation, so
their replies are latest-request-wins even when the two kinds race. Repository
matching resolves symlinks and uses the nearest `.git` directory or gitfile,
so a mutation from a sibling directory refreshes the same worktree view.
Every in-place refresh records both the fallback line and the selected status
path. Reordered rows therefore keep the cursor on the same file; rename rows
also match Git's original path. If the entry disappears, the cursor falls back
to the nearest surviving line (including the clean placeholder or header).

Default mappings (only installed when the keys are free; disable with `let g:simplegit_enable_default_mappings = 0`):

| Mapping | Action |
| --- | --- |
| `<leader>gb` | Blame sidebar |
| `<leader>gm` | Line blame popup |
| `<leader>gh` | File history |
| `<leader>gd` | Diff against HEAD |
| `<leader>gs` | Repository status |
| `]g` / `[g` | Next / previous hunk |
| `<leader>gp` | Preview hunk |
| `<leader>ga` | Stage hunk |
| `<leader>gu` | Undo hunk |

## Configuration

```vim
let g:simplegit_auto_enable = 1        " start on VimEnter
let g:simplegit_line_blame = 1         " inline current-line annotation
let g:simplegit_blame_delay = 350      " ms of cursor rest before it appears
let g:simplegit_blame_format = '%a, %w • %s'  " %a %e %h %d %w %s
let g:simplegit_blame_width = 34       " sidebar width
let g:simplegit_history_limit = 200    " max commits in :SimpleGitHistory
let g:simplegit_log_limit = 200        " commits per :SimpleGitLog page
let g:simplegit_signs = 1              " sign-column hunk markers
let g:simplegit_max_signs = 500        " place no signs above this count
let g:simplegit_hunk_delay = 300       " live-diff debounce while typing (ms)
let g:simplegit_status_auto_refresh = 1 " refresh open status after Focus/Shell
let g:simplegit_status_refresh_delay = 150 " external status refresh debounce
let g:simplegit_live_max_bytes = 1048576 " live-diff buffer size cap
let g:simplegit_daemon_path = ''       " explicit daemon binary path
```

See `:help simplegit` for the full reference, highlight groups, and troubleshooting.

## Development

`make check` runs the quality gate: `cargo fmt --check`, `cargo clippy -D warnings`, Rust protocol/parser/FIFO tests, and headless Vim smoke, real-Git, old-daemon capability and asynchronous UI-race tests. CI runs the same gate plus an installer/handshake verification.

## License

MIT

# Simplegit

Simplegit brings GitLens-style Git insight to Vim 9: an inline current-line blame annotation, a whole-file blame sidebar, file history, diff against any revision, commit inspection, a repository status window, and hunk handling: sign-column change markers with navigation, preview, stage and undo.

Like the other `simple*` plugins, rendering stays in Vim9script and all git work runs in a small asynchronous Rust daemon over a JSON line protocol — editing never waits on `git`.

## Features

- **Inline line blame** (GitLens style): `author, 3 days ago • commit summary` appears as virtual text after the current line, debounced and only when the buffer is unmodified.
- **Blame sidebar** (`:SimpleGitBlame`): per-line commit/date/author, scroll-synced with the file; `<CR>` opens the commit, `p` pops up its details, `q` closes.
- **File history** (`:SimpleGitHistory`): `git log --follow` for the current file; `<CR>` shows the commit's changes to this file, `a` the whole commit.
- **Diff against a revision** (`:SimpleGitDiff [rev]`): vertical `diffthis` split of the working file against HEAD or any revision.
- **Commit inspection** (`:SimpleGitShow [rev]`): message, stats and patch with `git` syntax highlighting.
- **Repository status** (`:SimpleGitStatus`): branch plus changed files; `<CR>` opens a file, `d` opens and diffs it, `a`/`u` stage/unstage it, `R` refreshes.
- **Line blame popup** (`:SimpleGitBlameLine`): commit, author, date, and summary for the line under the cursor.
- **Hunk handling** (GitGutter style): `+`/`~`/`_` signs for changes against the index — updated live while you type, without saving — plus hunk navigation (`:SimpleGitHunkNext`/`Prev`), a diff preview popup, and per-hunk stage (`:SimpleGitHunkStage`) and undo (`:SimpleGitHunkUndo`).
- Asynchronous daemon with a version handshake, request correlation, concurrency limiting and timeouts; `:SimpleGitHealth` diagnostics.

## Requirements

- Vim 9.1 with `+vim9script`, `+job`, `+channel`.
- Virtual text (patch 9.0.0067+) for the inline annotation; `+popupwin` for popups; `+timers` for debouncing. Everything else degrades gracefully.
- Git, and Rust/Cargo 1.85 or newer to build the daemon.

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
| `:SimpleGitDiff [rev]` | Diff file against `rev` (default `HEAD`) |
| `:SimpleGitShow [rev]` | Show a commit |
| `:SimpleGitStatus` | Repository status window |
| `:SimpleGitToggleLineBlame` | Toggle the inline annotation |
| `:SimpleGitHunkNext` / `:SimpleGitHunkPrev` | Jump to the next/previous hunk |
| `:SimpleGitHunkPreview` | Popup diff of the hunk under the cursor |
| `:SimpleGitHunkStage` | Stage the hunk under the cursor |
| `:SimpleGitHunkUndo` | Revert the hunk under the cursor |
| `:SimpleGitToggleSigns` | Toggle the sign-column markers |
| `:SimpleGitHealth` | Diagnostics |

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
let g:simplegit_blame_width = 34       " sidebar width
let g:simplegit_history_limit = 200    " max commits in :SimpleGitHistory
let g:simplegit_signs = 1              " sign-column hunk markers
let g:simplegit_max_signs = 500        " place no signs above this count
let g:simplegit_hunk_delay = 300       " live-diff debounce while typing (ms)
let g:simplegit_live_max_bytes = 1048576 " live-diff buffer size cap
let g:simplegit_daemon_path = ''       " explicit daemon binary path
```

See `:help simplegit` for the full reference, highlight groups, and troubleshooting.

## Development

`make check` runs the quality gate: `cargo fmt --check`, `cargo clippy -D warnings`, the Rust protocol/parser tests, and a headless Vim smoke test. CI runs the same gate plus an installer/handshake verification.

## License

MIT

# Changelog

## 0.2.0 (2026-07-25)

Hunk handling (protocol 2).

- Sign-column markers for working-tree changes against the index (`+`/`~`/`_`,
  event-driven refresh, `:SimpleGitToggleSigns`, `g:simplegit_max_signs` cap).
- Hunk navigation (`:SimpleGitHunkNext`/`:SimpleGitHunkPrev`, default `]g`/`[g`)
  and a diff preview popup (`:SimpleGitHunkPreview`, `<leader>gp`).
- Per-hunk stage into the index (`:SimpleGitHunkStage`, `<leader>ga`) and
  working-tree undo with buffer reload (`:SimpleGitHunkUndo`, `<leader>gu`).
- Daemon: `hunks`, `stage` and `undo` requests; extracted hunk headers are
  rebased on the apply target so isolated `-U0` hunks land on the right lines;
  protocol version bumped to 2 — rerun `./install.sh`.

## 0.1.0 (2026-07-25)

Initial release.

- Asynchronous Rust daemon (JSON line protocol, version handshake, protocol 1)
  with `blame`, `log`, `show`, `cat`, and `status` requests; concurrency
  limiting, per-request timeouts, request-path validation, and revision
  sanitizing.
- Inline current-line blame annotation as virtual text, debounced, with an
  uncommitted-changes marker.
- Scroll-synced blame sidebar with commit opening and detail popups.
- File history window backed by `git log --follow`.
- Diff of the current file against any revision via `diffthis`.
- Commit inspection window with git syntax highlighting.
- Repository status window with open/diff actions.
- `:SimpleGitHealth` diagnostics, `<Plug>` mappings, guarded defaults.

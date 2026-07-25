# Changelog

## 0.4.0 (2026-07-25)

Toolchain modernization release.

- Migrated to Rust edition 2024; minimum supported Rust is now 1.85.
- Refreshed the dependency lockfile.
- No behavior or protocol changes (protocol stays at 3). Rerun `./install.sh`.

## 0.3.0 (2026-07-25)

Live diffs, status-window staging, and robustness (protocol 3).

- Hunk signs update while typing: modified buffers are diffed against the
  index in the daemon (`hunks` request with buffer content, temp files plus
  `git diff --no-index`), debounced by `g:simplegit_hunk_delay` and capped by
  `g:simplegit_live_max_bytes`.
- Status window: `a` stages the file under the cursor, `u` unstages it, `R`
  refreshes; the list re-renders in place afterwards (`file_op` request).
- Scratch windows (status/history/show) are reused instead of stacking a new
  split per invocation.
- Signs update incrementally instead of unplace-all/replace, removing sign
  column flicker on every refresh.
- Buffer paths are resolved from buffer info instead of the current working
  directory, fixing "current buffer has no readable file" after `:cd`.
- Blame and hunk caches invalidate for every visible buffer on FocusGained
  and ShellCmdPost, so external commits/checkouts are picked up.
- The daemon is no longer respawned per request after repeated startup
  failures; `:SimpleGitEnable` retries explicitly.
- Protocol version bumped to 3 — rerun `./install.sh`.

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

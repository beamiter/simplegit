# Changelog

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

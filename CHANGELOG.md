# Changelog

## Unreleased - 2026-08-01

### 修复

- CI 仍在断言 `"protocol":1`,而 0.5.0 起 daemon 报告的是 4——这条流水线自协议
  升级后一直是坏的。
- daemon 崩溃后不再需要手动 `:SimpleGitEnable`:监督层会退避重启,并在重启完成
  后自动重新握手。`:SimpleGitEnable` 保留为熔断后的手动合闸入口。

### 变更

- `:SimpleGitHealth` 增加崩溃/重启计数与熔断状态。
- daemon 日志与提交图分开:`:SimpleGitLog` 仍是提交图,daemon 传输日志走
  `:SimpleGitDaemonLog`。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simplegit/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleGitRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleGitHealth`、`:SimpleGitRestart`、`:SimpleGitDaemonLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

## 0.5.0 (2026-07-26)

Repository commit graph (protocol 4).

- New `:SimpleGitLog` (default `<leader>gl`, `<Plug>(simplegit-log)`): a
  repository-wide `git log --graph` view with branch topology, short shas,
  dates, authors, refs and subjects. `<CR>` shows the commit under the
  cursor, `m` appends the next page (`--skip` paging), `q` closes.
- New daemon request `graph_log` with structured per-row output; connector
  rows (graph-only lines such as `|/`) are preserved so the topology renders
  exactly as git drew it. Malformed rows degrade to connector rows instead
  of misaligning columns.
- New options `g:simplegit_log_limit` (page size, default 200) and
  `g:simplegit_log_height` (window cap, default 20); new highlight groups
  `SimpleGitLogGraph`, `SimpleGitLogSha`, `SimpleGitLogRefs`.
- Protocol bumped to 4: rerun `./install.sh` so the Vim side and daemon
  stay in step.

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

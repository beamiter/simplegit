# Changelog

## Unreleased - 2026-08-01

### 新增:提交

- `:SimpleGitCommit` / `:SimpleGitCommit!`(amend):在 scratch buffer 里写提交信息,
  `:w` 提交、`q` 放弃;以 `#` 开头的行会被剥掉,底部的帮助文字不会混进 message。
- 提交信息走 daemon 的 stdin 而不是命令行参数,空行、引号、非 ASCII 都原样保留。
- `--amend` 会先取回上一条 message 预填,是"编辑"而不是"悄悄替换"。
- 状态窗口内 `c` 提交、`C` amend。
- 协议升到 5:新增 `commit` 与 `commit_message` 请求。升级后请重新运行
  `./install.sh`,让 Vim 侧与 daemon 保持一致。

### 修复

- daemon 现在接受数字形式的布尔值。Vim 的 `<bang>0` 与多数选项读出来都是 0/1,
  `json_encode()` 会原样写成 `0`,而 serde 的 `bool` 直接拒收整个请求。
- 从 scratch 窗口(状态视图)发起提交会认错仓库:那些窗口没有文件名,
  `expand('%:p:h')` 不是目录,于是回退到 `getcwd()`——提交会落到 Vim 启动时所在的
  仓库,而不是状态视图正在显示的那个。而 `c` 正是提交的主要入口。现在优先使用
  buffer 自己记录的仓库目录。
- 新增 `tests/vim_commit.vim`:在临时仓库里跑真实的 `git commit`,覆盖带正文的
  message、注释剥离、空 message 不提交且不丢内容、amend 预填与不新增提交,以及
  从状态窗口提交必须落在正确的仓库。测试全程 `cd` 到一个诱饵仓库,既能真正暴露
  "回退到 getcwd()" 的错误,又保证插件出错时也伤不到被测仓库本身。

### 构建与 CI 修复

- 修复 `doc/simplegit.txt` 中重复的 help tag(`:SimpleGitHealth`),`helptags` 会因此报错并让 `install.sh` 失败。
- 新增 CI 的 MSRV 作业。

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

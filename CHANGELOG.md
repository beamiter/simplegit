# Changelog

## Unreleased - 2026-08-08

### 修复:`color.ui = always` 会把 ANSI 转义码渲染进 scratch buffer

- 只有 diff 那几条路径带了 `--no-color`;`blame` / `log` / `graph_log` / `show` /
  `status` 都没有。而 `color.ui = always`(为了把 git 接到 pager 而设,很常见)
  即使 stdout 不是 tty 也照样上色,于是 commit graph 里出现字面量
  `\e[31m|`、图形列对不齐、sha 的 syntax match 也不再匹配。
- 改为在 `git_command()` 里统一关闭颜色,位置在子命令之前:以后新增的子命令不可能
  漏掉这一条。
- 只关 `color.ui` 不够:git 先看 `color.<slot>`,`color.ui` 只是这些 slot 的默认
  值,所以设了 `color.diff = always` 的用户在 `-c color.ui=false` 之下 `:SimpleGitShow`
  照样是带转义码的(`git branch` 之于 `color.branch` 同理)。现在把每一个能强行
  打开颜色的 slot 都点名关掉。`color.decorate` 不在其列:它的子键存的是颜色名而不是
  always/never,decoration 跟随 log 自己的颜色判定,而那个判定由 `color.diff` 决定。
- 新增单元测试在一个把所有 color slot 都打开的临时仓库里跑 `show` / `log` /
  `graph_log` / `blame` / `blame_line` / `status` / `branch` / `hunks` / `cat`,断言
  **回包里**没有转义码。原来那条只断言 argv 的测试正是因此漏掉了上面这个 bug,现在
  它只负责断言顺序(设置必须排在子命令前面)。

### 修复:`g:simplegit_version` 停在 0.3.0

- crate 和 daemon 报 0.5.0,而用户唯一能在不启动 daemon 的情况下读到、也是写进
  bug report 的那个版本号还是 0.3.0。这个变量代码里没人读,所以漂了两个版本也没
  人发现。
- 现在与 Cargo.toml 对齐,并由 `make vim-test` 在两者不一致时直接让构建失败。

### 新增:daemon 主动上报仓库变化,不再等 `FocusGained`

- 别的终端里 `git checkout` 之后,signs / blame / 分支全是错的,要等 `FocusGained`
  或 `ShellCmdPost` 才纠正——而 `ShellCmdPost` 只覆盖 Vim 自己跑的命令,
  `FocusGained` 在不上报焦点的终端里**根本不会触发**(tmux 里一个 pane 跑 Vim、
  隔壁 pane 跑 git,正是这个场景)。
- daemon 现在按仓库轮询 git 目录(HEAD、index、refs/heads、packed-refs、
  logs/HEAD、MERGE_HEAD;不碰工作树——工作树的变化 Vim 自己知道),变化时推送一条
  不对应任何请求的 `repo_change`。Vim 侧把它当成"作用域限定到该仓库的
  FocusGained":只刷新属于这个仓库的可见 buffer,别的仓库一动不动。
- 每个仓库注册一次 watch(不是每个 buffer),每个 daemon 最多 32 个;新能力
  `repo_watch`,旧 daemon 上什么都不发。新选项 `g:simplegit_watch`(默认开)、
  `g:simplegit_watch_interval`(默认 2000ms,低于 200ms 会被 daemon 抬到 200ms),
  `:SimpleGitHealth` 新增 `repo watch` 一行。轮询而不用 inotify:依赖仍然只有
  serde + tokio,各平台行为一致,代价是每个仓库每轮 6 个 stat。
- 测试:新增 `make vim-watch`(fixture 可按需推送任意非请求事件),覆盖每仓库只注册
  一次、推送后确实重读、另一个仓库的变化不影响本 buffer、未注册的 root 被忽略、
  daemon 重启后重新注册、关掉开关后线上什么都没有;`make vim-integration` 再用真
  daemon 跑一遍:`system()` 里跑 `git add`(不触发任何 autocommand),断言 signs
  自己消失。

### 新增:按范围 stage/revert/preview hunk,以及 `ih` / `ah` text object

- `:SimpleGitHunkStage` / `:SimpleGitHunkUndo` / `:SimpleGitHunkPreview` 现在接受
  range:可视选区(`<leader>ga` / `<leader>gu` / `<leader>gp` 在 visual mode 也
  映射好了)或 `:10,20SimpleGitHunkStage`,作用于选区碰到的**每一个** hunk。纯删除
  没有自己的行,只能通过 sign 所在的那一行被选中——Vim 侧与 daemon 侧用的是同一
  条规则,否则 preview 和 stage 会各看各的。
- daemon 把选中的 hunk 合成**一个** patch 交给 `git apply`,而不是一个 hunk 一次
  进程:`git apply` 是全有或全无的,所以一个 range 要么整体生效,要么索引原样不动,
  不会停在"staged 一半"。被丢掉的 hunk 会让保留下来的 hunk 在非目标一侧发生位移,
  header 因此按累计增量重新基准化(stage 基准在 index 侧,revert 在工作树侧)。
- 新协议能力 `hunk_range`(协议号仍是 5,能力是加上去的)。旧 daemon 不认识
  `last_lnum`,只会 stage 选区第一行的那个 hunk——那不是用户要的,所以带 range 的
  请求在线上就被能力门挡住并明确报错,而不是悄悄缩小范围。`:SimpleGitHealth`
  新增一行 `hunk ranges`。
- 新增 `ih` / `ah` text object(visual + operator-pending,仅在按键未被占用时安装):
  `dih` 删掉光标所在 hunk,`ah` 额外吃掉紧随其后的空行。text object 不能等待,
  所以 hunk 还没读回来时它明确拒绝,而不是选错行。
- 测试:Rust 单元测试覆盖多 hunk patch 的 header 重定基准(正向/反向、纯插入/
  纯删除、以及 delta 不会把起点压到负数);`make vim-integration` 用真 git 跑一遍
  端到端——窄 range 只 stage 它碰到的 hunk、整文件 range 三个 hunk 一次 `git apply`
  成功、反向 range revert 逐字节还原文件、`ih` 选中插入的那一行且在 hunk 之外
  什么都不选。

### 修复:重新读入 buffer 之后 signs 不会更新

- `BufReadPost` 走的是 `RefreshHunks()`,而它只在缓存为空时才去问 daemon,否则
  直接用旧结果重画。于是任何一次「buffer 被重新读入」——`:edit!` 丢弃修改、
  `git checkout` 之后 `'autoread'` 重新载入、revert hunk 之后的自动重载——都还在
  按被替换掉的那份文本画 signs。实测这批过时的 signs 多数时候会在约
  `g:simplegit_hunk_delay`(默认 300ms)之后自己纠正:重新读入同样触发
  `TextChanged`,它 debounce 之后又问了一次 daemon。但那只是搭了便车:没有
  `+timers` 的 Vim 上 `ScheduleHunks()` 直接返回,而计时器触发时问的是**当时**的
  当前 buffer,在它触发之前切走就没人再问了——缓存非空,之后每一次 `BufEnter` 都
  只是把同一批过时的 signs 再画一遍。blame 缓存同理。
- `BufReadPost` 与 `BufEnter` 现在分开:前者说的是「这段文本被换掉了」,会先让
  hunk/blame 缓存失效再刷新;后者只是「你正在看它」,保持原样。
- `make vim-integration` 新增回归:live diff 标出未保存修改之后 `:edit!` 丢弃它,
  断言 `simplegit#HunkSummary()` 在**下一条语句**上就已经归零。只等 sign 消失锁不住
  这个修复——上面那个 debounce 会在 `WaitFor` 的预算之内把它救回来。

### 修复:in-flight 的 branch 读会吞掉一次外部 checkout

- 外部变更(`FocusGained`/`ShellCmdPost`)只清空 `s_branch_cache`,却留着
  `s_branch_inflight`。如果 checkout 恰好落在一次 branch 读已经上路、回复还没到
  的窗口里,`EnsureBranch()` 会因为 in-flight 标记直接返回、不再问;而那条陈旧的
  回复落地时又把**切换前**的分支写回缓存。结果是 statusline 显示旧分支,而且缓存
  已被填满,要等下一次外部事件或 `:SimpleGitRestart` 才会纠正。
- 现在缓存与 in-flight 标记一起失效,并引入 generation:回复带着自己发出时的
  generation,不匹配就丢弃。于是重问立刻发出,陈旧回复(哪怕后到)也进不了缓存;
  失败回复走同一条规则。
- `make vim-statusline` 新增回归:第一次读被压住 500ms,期间触发一次外部变更,
  断言第二次请求确实上了线、分支最终是新的,并且在陈旧回复落地之后仍然是新的。

### 修复:live diff 的临时文件

- 未保存 buffer 的 live diff 此前写到 `$TMPDIR/simplegit-<pid>-<id>.buffer`:
  pid 可从 /proc 读到、request id 单调递增,所以路径可预测;`tokio::fs::write`
  会跟随符号链接,而且文件是 0644——共享 /tmp 上每次连续输入都把未保存内容
  摊开给别人看。现在改为 0700 的私有目录,文件用 `create_new` + 0600 创建
  (路径已存在就报错而不是写穿),diff 返回即删除。
- 该目录改为**每次 diff** 创建、diff 结束即回收。此前是每个 daemon 一个、
  只在 `main()` 正常返回时删除——而 daemon 永远是被信号杀死的(simplecore 发
  SIGTERM,必要时升级到 SIGKILL),`main()` 的收尾根本不会执行,于是每个跑过
  live diff 的 daemon 都会留下一个空目录:每个 Vim session 一个、每次
  `:SimpleGitRestart` 一个、每次 daemon 崩溃重启一个。旧版本遗留在 `$TMPDIR`
  下的空 `simplegit-<pid>-<nonce>` 目录可以直接删除。
- 新增单元测试断言目录/文件权限,以及"预置符号链接必须写不进去、目标内容不变";
  另有一个端到端测试跑一次真实的 live diff,断言事后目录里什么都不剩。

### 修复:正在写的 commit message 会被覆盖

- 在 tab 1 写了一半 commit message,再从别的 tab 执行 `:SimpleGitCommit`:
  `OpenScratch()` 的"保留未保存文本"分支会把用户拽回 tab 1,并把那个**没有清空**
  的 buffer 交给调用方。`Commit()` 随后 `setline(1, body)` 只覆盖前几行,旧
  message 的尾巴就留在注释块下面,`:w` 会把它当作新 commit 的正文提交上去。
- 现在 `OpenScratch()` 无论走哪条分支都返回一个空 buffer(调用方本来就是这么
  假设的),未保存的 message 改由 `:SimpleGitCommit` 自己保护:有未保存 message
  时直接拒绝并告知它在第几个 tab,请先 `:w` 提交或 `q` 放弃。焦点不会被拽走,
  message 也一个字都不会丢。
- `make vim-commit` 新增回归:跨 tab 二次 `:SimpleGitCommit` 不移动焦点、不新开
  buffer、原 message 逐行不变;放弃之后下一次拿到的是干净模板。

### 修复:statusline accessor 其实在做文件系统 I/O

- 文档承诺这些 accessor"只读缓存、不派发请求、不阻塞",但每次调用都要经
  `BufRepoToken()` → `RepoToken()`:`resolve()` 对路径的每一段做一次 readlink,
  再逐级向上 `isdirectory()`/`filereadable()` 找 `.git`。实测一个几层深的文件
  每次求值约 33 个 syscall、0.27 ms,而 'statusline' 是每次 redraw、每个窗口、
  每个插入模式按键都要求值的——在 NFS/sshfs 上这就是 redraw 卡顿。返回空串的
  情况下这笔开销照付不误。
- 现在按 buffer 记住仓库 token(以 buffer 名为键,所以 buffer 号被回收也不会
  串味),仅在 `FocusGained`/`ShellCmdPost` 这类外部变更时整体失效。同一测量
  从 66021 个 syscall / 0.53 s(2000 次调用)降到 54 个 / 0.011 s。
- `make vim-statusline` 新增回归:把 `.git` 移开之后 accessor 仍答得出分支,
  即"它没有再去问文件系统"。

### 修复:`g:simplegit_signs = 0` 时没有 `b:simplegit_status_dict`

- 文档说"每个 file buffer 都带 `b:simplegit_status_dict`",但 buffer 路径上唯一
  的发布点在 `SignsEnabled()` 之后:关掉 signs 时不会请求 hunks,于是除了恰好赶上
  branch 回复的第一个 buffer 之外,其余 buffer 上这个变量根本不存在,按文档写的
  `%{b:simplegit_status_dict.head}` 每次都是 E121。
- 现在 `RefreshHunks()` 在 `EnsureBranch()` 之后、signs 判断之前就发布,与 signs
  开关无关。关掉 signs 时行数保持 0(没人去读 hunks),`head` 照常。
- `make vim-statusline` 新增回归:signs 关闭后打开的 buffer 必须带上该变量与分支,
  且不产生任何 hunks 请求。

### 修复:第一次按 `]g` 会被吞掉

- `RequestHunks()` 在已有请求 in-flight 时直接 `return true`,只置 stale 位,
  purpose 就此丢失。而 `BufReadPost` 必然会给每个 file buffer 起一次刷新,所以
  "刚打开文件就按 `]g`" 命中的正是这条路径:不跳转、不报错、按键凭空消失
  (`[g` 与 hunk preview 同理)。现在会把这个动作排队,答案到达时执行;期间又按了
  别的键则最后一次生效。UI 动作不再顺带置 stale 位,少一次多余的 git 调用。
- hunks 请求失败时会清掉排队动作并明确提示,而不是让按键无声消失。
- 新增 `make vim-hunks` 回归。

### 异步打开的 view 也带 origin 守卫

- `show` / `log` / `graph_log` / `cat` 的回复此前没有任何 origin 检查:慢一点的
  `:SimpleGitDiff` 回来时会 `win_gotoid(src_win)` 把光标拽回原窗口、开 diff split;
  `:SimpleGitShow` 则通过 `getwininfo()`(它会枚举所有 tab)复用同名 scratch 窗口,
  直接把用户拖到另一个 tab——这与 README 里"回复不会在你走开后抢回焦点"的承诺相反。
  现在它们与 status/commit 用同一套规则:记录发起的 tab/window/buffer + repo token
  + 代际,投递时重新校验,不满足就丢弃。
- `OpenScratch()` 的复用改为只在当前 tab 内进行;同名 scratch 属于别的 tab 时就地
  retire(未保存的 commit message 由 `:SimpleGitCommit` 自己拒绝来保护,见上文,
  而不是把没清空的 buffer 交给调用方)。`OpenStatusScratch()` 因此并入
  `OpenScratch()`,status 行为不变。
- commit graph 翻页(`m`)改用 `win_execute()`/`appendbufline()`,即使目标窗口
  已经在别的 tab 也不会切换焦点。
- 新增 `make vim-views` 回归:跨 tab 复用、迟到的 diff/show/history 回复不抢焦点
  不开窗、以及同一 view 的两次请求 latest-wins。

### 单行 blame

- 内联注释此前为了标注一行而 blame 整个文件:在大文件+深历史上就是数秒的 git,
  外加"每行一个 40 字符 sha + 一整块 header"的 JSON 在 Vim 主线程上解码,而且
  每次 `:w` 都要重来一遍。现在改为 `git blame --porcelain -L n,n`,只标注光标
  所在的那一行,并按行缓存(带 changedtick 校验,飞行途中发生编辑的回复会被丢弃)。
- `:SimpleGitBlameLine` 的 popup 走同一条路径,同样只 blame 一行。
- 侧边栏(`:SimpleGitBlame`)仍然一次读整个文件;只要那份缓存还在,注释就直接
  复用它,不会再按行发请求。
- `handle_blame` 从 `--line-porcelain` 换成 `--porcelain`:同一 commit 的后续行
  只重复 sha 而不重复整块 header,stdout 通常小一个数量级。`parse_blame` 本就
  依赖 `entry().or_insert_with()` 保留首块,现在补了针对缩略输出的测试把这一点钉住。
- 新增 `g:simplegit_blame_format`(默认 `'%a, %w • %s'`,键 `%a %e %h %d %w %s %%`)
  与公开的 `simplegit#BlameAnnotation()`。缓存的是原始字段而不是渲染结果,所以
  改 format 立即生效、无需重新取数。
- capability `blame_line`(protocol 仍为 5):旧 daemon 保持原有整文件行为。
- 新增 `make vim-blame` 回归。

### Statusline API

- 新增公开、稳定的 statusline 接口:`simplegit#StatusLine()` 直接给出
  `main ↑2 ↓1 +12 ~3 -1`;`simplegit#StatusDict()` / `simplegit#Head()` /
  `simplegit#HunkSummary()` 给出同一份数据的结构化形式;每个 file buffer 上
  同步 `b:simplegit_status_dict`(对标 gitsigns 的
  `b:gitsigns_status_dict` 与 `FugitiveStatusline()`),并在其变化时触发
  `User SimpleGitUpdate`——仅在确有监听者时才触发。
- 这些 accessor 全部只读已有缓存:O(cached hunks)、不派发请求、不阻塞,可以
  安全放进每次 redraw 都会求值的 'statusline'。branch 改为按 **仓库** 读取一次
  (不是按 buffer),由 buffer 生命周期与 `FocusGained`/`ShellCmdPost` 触发。
- daemon 新增轻量的 `branch` 请求(capability `branch_summary`,protocol 仍为 5):
  只读两个 ref(`symbolic-ref` + `rev-list --count --left-right`),不像
  `git status -b` 那样遍历整个 worktree;detached HEAD 回退到 short sha,
  unborn branch 也能正确报出分支名。旧 daemon 没有该 capability 时 fail closed:
  `head` 为空、`StatusLine()` 返回空串,不会把它答不了的请求送上线。
- `status` 事件补上 `ahead`/`behind`(解析 `# branch.ab`),status 窗口标题因此
  会显示 `## main ↑2 ↓1`,并顺带把 branch 缓存喂热——开着 status 窗口时不产生
  额外的 branch 读取。
- 新增 `make vim-statusline` 回归:capability fail-closed、每仓库只读一次、
  hunk 行数折叠、`b:` 变量与 User 事件,以及"求值 50 次不发任何请求"。

### CI 的 MSRV pin 修复

- `.github/workflows/ci.yml` 的 `dtolnay/rust-toolchain` 停在 1.85.0,而
  Cargo.toml 声明 `rust-version = "1.88"`。cargo 把更高的 rust-version 当作硬
  错误,所以 msrv job 在编译任何代码之前就失败——每次 push 都是红的。pin 提到
  1.88.0,并新增一步从 Cargo.toml 提取 `rust-version` 与实际安装的 rustc 比对
  major.minor,不一致就带说明失败,下次抬 MSRV 不会再悄悄漏掉这个 pin。

### Status 光标跟随文件

- 手动、自动及 mutation 后的 status 刷新同时记录所选 path 与备用行号；条目
  重排时光标跟随同一文件,rename 可通过 `orig` 识别原路径,不再落到碰巧占据旧
  行号的另一文件。
- 所选条目消失时才回退到最近存活行；header 与 clean placeholder 保持合理
  位置。路径恢复仍受精确 winid/bufnr/repository 与 generation 约束,迟到响应
  不能移动光标或抢走跨 tab 焦点。
- fake-daemon 回归覆盖重排、rename、删除、clean/header、跨 tab 回复及双请求
  latest-wins。

### Status 自动保鲜

- 已打开的 status view 现在会在 `FocusGained` / `ShellCmdPost` 后自动刷新;
  `g:simplegit_status_auto_refresh` 默认 1、可显式关闭;
  `g:simplegit_status_refresh_delay` 默认 150 ms,连续事件合并为一次请求。
- 自动请求只针对仍存在的 status winid+bufnr+repository,沿用 generation
  latest-wins;跨 tab 回复只原地更新目标,不会抢走当前 tab/window/buffer。目标在
  timer 到期前关闭时不发请求、更不会复活窗口。
- 显式 `:SimpleGitStatus` 与原地 automatic refresh 现在共用 status buffer 的
  generation:显式请求派发时即预留代际,所以 old-auto→explicit 与
  explicit→new-auto 两个方向的迟到回复都不能覆盖新结果。repository identity
  会 resolve symlink 并向上寻找最近的 `.git` directory/gitfile,同 worktree 的
  sibling 目录可正确汇合,不同仓库仍严格隔离。
- `R` 立即刷新;有有效 status target 的 file-op/commit 也立即刷新,并只从挂起的
  全局 timer 排除自己的 repository,不会吞掉其他仓库的外部变更。普通 buffer
  发起、没有 target 的 mutation 则让同仓库已打开 status 走一次去抖刷新,不会漏更
  也不会重复查询。`:SimpleGitDisable` 后残留 scratch 不能借 Focus 事件重启 daemon。
  `:SimpleGitHealth` 显示开关、debounce 与 pending 状态;fake-daemon 回归覆盖 burst、
  跨 tab、两类 mutation、关闭目标与 Disable 生命周期。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--version`/`--help`/`--self-test`:此前 daemon 完全忽略命令行参数。
  `--self-test` 用内存管道把一条真实请求走完 parse → dispatch → reply。
- 状态窗口新增 `A` / `U`,可一次暂存/取消暂存整个仓库;对应命令为
  `:SimpleGitStageAll` / `:SimpleGitUnstageAll`,并且从子目录调用时范围仍是仓库根。
- 整仓操作现在通过 protocol 5 的增量 capability `repository_file_ops` 协商。
  新 Vim 遇到同为 protocol 5、但未声明该能力的旧 daemon 时只拒绝这两个命令并
  提示重跑 `./install.sh`,不会把未知 op 发上 wire;其他旧功能继续可用。
- 所有依赖 Git index 的写操作(hunk stage/undo、文件与整仓 stage/reset、commit)
  进入 daemon 的单一 FIFO 通道,严格按请求顺序完成,不再互相争抢 `index.lock`;
  blame/log/status 等只读请求仍保持并发。
- status、file-op 与 commit 的异步结果会记录发起 tab/window/buffer/repository,
  只定向刷新仍存活且仍属于同一仓库的 status view。用户已切 tab、关掉窗口或把
  同一窗口用于别的仓库时不会被拉回;初次打开与定向刷新都按代际号 latest-wins。
- commit message 同样带代际与 changedtick:一次 `:write` 尚未返回时拒绝重复提交;
  若用户在回复前继续输入,成功回调会保留这段新文字并保持 modified,不会清空/关窗。
  daemon 输入 I/O 失败时也会先 drain 已排队的 index 操作与输出再返回错误。
- 新增插件专用 fake daemon 与 Vim 回归测试,覆盖握手前排队到旧 protocol-5 端的
  fail-closed、跨 tab 不抢焦点、关闭/换仓目标不复活、初次/刷新 status 乱序、
  commit 后续编辑保留,以及 Rust 端 burst `add`→`reset` 与输入错误 drain。

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

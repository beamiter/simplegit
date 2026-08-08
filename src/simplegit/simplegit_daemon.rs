use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::io::{self, AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::task::{JoinError, JoinSet};

const GIT_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_CONCURRENT_GIT_REQUESTS: usize = 4;
const MAX_REQUEST_PATH_BYTES: usize = 4096;
// Live hunk requests carry whole buffer contents.
const MAX_CONTENT_BYTES: usize = 2 * 1024 * 1024;
// A valid request may expand sixfold when JSON escapes ASCII control bytes.
// Keep enough headroom for the envelope and a maximum-width u64 request ID.
const MAX_REQUEST_LINE_BYTES: usize = (MAX_REQUEST_PATH_BYTES + MAX_CONTENT_BYTES) * 6 + 1024;
const MAX_OUTPUT_LINES: usize = 200_000;
const MAX_PENDING_INDEX_MUTATIONS: usize = 1024;
const PROTOCOL_VERSION: u32 = 5;
const CAP_REPOSITORY_FILE_OPS: &str = "repository_file_ops";
const CAP_BRANCH_SUMMARY: &str = "branch_summary";
const CAP_BLAME_LINE: &str = "blame_line";
const CAP_HUNK_RANGE: &str = "hunk_range";
const GIT_REPOSITORY_ENV_VARS: [&str; 8] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
];

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "version")]
    Version { id: u64 },
    /// Whole-file blame, for the sidebar.
    #[serde(rename = "blame")]
    Blame { id: u64, path: String },
    /// Blame for a single line (`git blame -L`). The inline annotation shows
    /// one line at a time, and blaming the whole file to render it costs
    /// seconds on a large file with deep history.
    #[serde(rename = "blame_line")]
    BlameLine { id: u64, path: String, lnum: u32 },
    /// Commit history that touched one file.
    #[serde(rename = "log")]
    Log {
        id: u64,
        path: String,
        #[serde(default)]
        limit: u32,
    },
    /// Repository-wide commit graph (`git log --graph`), with paging.
    #[serde(rename = "graph_log")]
    GraphLog {
        id: u64,
        path: String,
        #[serde(default)]
        limit: u32,
        #[serde(default)]
        skip: u32,
    },
    /// A commit (message plus patch), optionally restricted to one file.
    #[serde(rename = "show")]
    Show {
        id: u64,
        path: String,
        rev: String,
        #[serde(default)]
        file: Option<String>,
    },
    /// File contents at a revision, for diff-against-rev.
    #[serde(rename = "cat")]
    Cat { id: u64, path: String, rev: String },
    /// Branch plus changed-file list for the repository containing `path`.
    #[serde(rename = "status")]
    Status { id: u64, path: String },
    /// Current ref and upstream distance only, for the statusline API. Unlike
    /// `status` this reads two refs and never walks the worktree, so it is
    /// cheap enough to run once per repository on buffer entry.
    #[serde(rename = "branch")]
    Branch { id: u64, path: String },
    /// Working-tree-vs-index hunks for one file (`git diff -U0`). With
    /// `content` the buffer text is diffed against the index instead of the
    /// file on disk, so signs can track unsaved edits.
    #[serde(rename = "hunks")]
    Hunks {
        id: u64,
        path: String,
        #[serde(default)]
        content: Option<String>,
    },
    /// Stage the hunk covering line `lnum` (`git apply --cached`). With
    /// `last_lnum` set, every hunk overlapping `lnum..=last_lnum` goes in one
    /// patch instead; omitting it means a one-line range, which is what a
    /// client that predates hunk ranges sends.
    #[serde(rename = "stage")]
    Stage {
        id: u64,
        path: String,
        lnum: u32,
        #[serde(default)]
        last_lnum: Option<u32>,
    },
    /// Revert the hunk covering line `lnum` (or the `lnum..=last_lnum` range)
    /// in the working tree.
    #[serde(rename = "undo")]
    Undo {
        id: u64,
        path: String,
        lnum: u32,
        #[serde(default)]
        last_lnum: Option<u32>,
    },
    /// Stage or unstage one file or the whole repository. Repository-wide
    /// operations use "add_all"/"reset_all" and ignore `file`.
    #[serde(rename = "file_op")]
    FileOp {
        id: u64,
        path: String,
        op: String,
        file: String,
    },
    /// The full message of HEAD, used to pre-fill an amend so the user edits
    /// the existing message instead of retyping it.
    #[serde(rename = "commit_message")]
    CommitMessage { id: u64, path: String },
    /// Commit what is staged. The message arrives over stdin rather than as an
    /// argv entry, so it can contain newlines and needs no shell quoting.
    #[serde(rename = "commit")]
    Commit {
        id: u64,
        path: String,
        message: String,
        /// Vim has no distinct boolean in many contexts -- `<bang>0` and most
        /// option reads produce 0 or 1 -- so accept a number here as well as a
        /// JSON boolean rather than rejecting the whole request.
        #[serde(default, deserialize_with = "lenient_bool")]
        amend: bool,
    },
}

#[derive(Debug, Serialize, Clone, Default, PartialEq, Eq)]
struct CommitInfo {
    author: String,
    /// Bare address, angle brackets stripped, for `%e` in the annotation.
    email: String,
    time: i64,
    summary: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
struct LogEntry {
    sha: String,
    author: String,
    time: i64,
    subject: String,
}

/// One rendered `git log --graph` line. Connector-only lines (for example
/// `|/` or `| *` without a commit) carry an empty `sha` and empty fields.
#[derive(Debug, Serialize, PartialEq, Eq)]
struct GraphRow {
    graph: String,
    sha: String,
    date: String,
    author: String,
    refs: String,
    subject: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
struct Hunk {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    /// The `@@` header plus the hunk body, for previews.
    lines: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
struct StatusEntry {
    xy: String,
    path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    orig: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "version")]
    Version {
        id: u64,
        version: &'static str,
        protocol: u32,
        capabilities: HashMap<&'static str, bool>,
    },
    #[serde(rename = "blame")]
    Blame {
        id: u64,
        path: String,
        lines: Vec<String>,
        commits: HashMap<String, CommitInfo>,
    },
    #[serde(rename = "blame_line")]
    BlameLine {
        id: u64,
        path: String,
        lnum: u32,
        /// All zeroes for a line that is not committed yet.
        sha: String,
        author: String,
        email: String,
        time: i64,
        summary: String,
    },
    #[serde(rename = "log")]
    Log {
        id: u64,
        path: String,
        entries: Vec<LogEntry>,
    },
    #[serde(rename = "graph_log")]
    GraphLog {
        id: u64,
        path: String,
        skip: u32,
        rows: Vec<GraphRow>,
    },
    #[serde(rename = "show")]
    Show { id: u64, lines: Vec<String> },
    #[serde(rename = "cat")]
    Cat { id: u64, lines: Vec<String> },
    #[serde(rename = "status")]
    Status {
        id: u64,
        path: String,
        branch: String,
        /// Upstream distance, for statusline consumers. Additive fields: a
        /// client that predates them simply never reads them.
        ahead: i64,
        behind: i64,
        entries: Vec<StatusEntry>,
    },
    #[serde(rename = "branch")]
    Branch {
        id: u64,
        path: String,
        /// Branch name, or the short sha when HEAD is detached.
        head: String,
        ahead: i64,
        behind: i64,
    },
    #[serde(rename = "hunks")]
    Hunks {
        id: u64,
        path: String,
        hunks: Vec<Hunk>,
    },
    #[serde(rename = "hunk_op")]
    HunkOp {
        id: u64,
        action: &'static str,
        path: String,
    },
    #[serde(rename = "file_op")]
    FileOp { id: u64, op: String, path: String },
    #[serde(rename = "commit_message")]
    CommitMessage {
        id: u64,
        path: String,
        lines: Vec<String>,
    },
    #[serde(rename = "commit")]
    Commit {
        id: u64,
        path: String,
        /// Short sha of the new commit.
        sha: String,
        subject: String,
        /// git's own summary line, shown verbatim so the user sees exactly
        /// what git reported.
        summary: String,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

type EventTx = tokio::sync::mpsc::Sender<String>;

/// Operations that mutate the index, plus hunk undo whose patch must be based
/// on a stable index.  A single FIFO worker owns this queue, so mutations are
/// applied in request order instead of racing in the general-purpose request
/// pool and intermittently failing on `index.lock`.
enum IndexMutation {
    HunkStage {
        id: u64,
        path: String,
        lnum: u32,
        last_lnum: u32,
    },
    HunkUndo {
        id: u64,
        path: String,
        lnum: u32,
        last_lnum: u32,
    },
    FileOp {
        id: u64,
        path: String,
        op: String,
        file: String,
    },
    Commit {
        id: u64,
        path: String,
        message: String,
        amend: bool,
    },
    #[cfg(test)]
    Probe {
        id: u64,
        delay_ms: u64,
        observed: Arc<std::sync::Mutex<Vec<u64>>>,
    },
}

impl IndexMutation {
    fn id(&self) -> u64 {
        match self {
            Self::HunkStage { id, .. }
            | Self::HunkUndo { id, .. }
            | Self::FileOp { id, .. }
            | Self::Commit { id, .. } => *id,
            #[cfg(test)]
            Self::Probe { id, .. } => *id,
        }
    }
}

fn protocol_capabilities() -> HashMap<&'static str, bool> {
    HashMap::from([
        (CAP_REPOSITORY_FILE_OPS, true),
        (CAP_BRANCH_SUMMARY, true),
        (CAP_BLAME_LINE, true),
        (CAP_HUNK_RANGE, true),
    ])
}

async fn stdout_writer<W>(mut out: W, mut rx: tokio::sync::mpsc::Receiver<String>) -> io::Result<()>
where
    W: AsyncWrite + Unpin,
{
    while let Some(line) = rx.recv().await {
        out.write_all(line.as_bytes()).await?;
        out.write_all(b"\n").await?;
        out.flush().await?;
    }
    Ok(())
}

async fn send_event(out: &EventTx, evt: &Event) {
    if let Ok(line) = serde_json::to_string(evt) {
        let _ = out.send(line).await;
    }
}

// ---------------------------------------------------------------------------
// Git plumbing
// ---------------------------------------------------------------------------

/// Accept `true`/`false`, `0`/`1`, or a missing field. The Vim side routinely
/// has numeric booleans, and a type error there would fail an entire request
/// for a flag that is merely off.
fn lenient_bool<'de, D>(deserializer: D) -> Result<bool, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize;
    Ok(match serde_json::Value::deserialize(deserializer)? {
        serde_json::Value::Bool(value) => value,
        serde_json::Value::Number(value) => value.as_i64().unwrap_or(0) != 0,
        serde_json::Value::Null => false,
        _ => false,
    })
}

fn file_dir(path: &str) -> PathBuf {
    let path = Path::new(path);
    if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf()
    }
}

fn file_name(path: &str) -> Result<String, String> {
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .ok_or_else(|| format!("path has no file name: {path}"))
}

fn git_command(dir: &Path, args: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("git");
    command
        .args(args)
        .current_dir(dir)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .kill_on_drop(true);
    for variable in GIT_REPOSITORY_ENV_VARS {
        command.env_remove(variable);
    }
    command
}

async fn run_git_coded(dir: &Path, args: &[&str], ok_codes: &[i32]) -> Result<String, String> {
    let output = tokio::time::timeout(GIT_TIMEOUT, git_command(dir, args).output())
        .await
        .map_err(|_| {
            format!(
                "git {} timed out after {} seconds",
                args.first().copied().unwrap_or(""),
                GIT_TIMEOUT.as_secs()
            )
        })?
        .map_err(|error| format!("failed to run git: {error}"))?;

    let accepted = output.status.success()
        || output
            .status
            .code()
            .is_some_and(|code| ok_codes.contains(&code));
    if !accepted {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first = stderr.lines().next().unwrap_or("git command failed");
        return Err(first.to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

async fn run_git(dir: &Path, args: &[&str]) -> Result<String, String> {
    run_git_coded(dir, args, &[]).await
}

async fn run_git_with_input(dir: &Path, args: &[&str], input: String) -> Result<String, String> {
    let mut command = git_command(dir, args);
    command
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let run = async {
        let mut child = command
            .spawn()
            .map_err(|error| format!("failed to run git: {error}"))?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or_else(|| "failed to open git stdin".to_string())?;
        stdin
            .write_all(input.as_bytes())
            .await
            .map_err(|error| format!("failed to write git stdin: {error}"))?;
        drop(stdin);
        child
            .wait_with_output()
            .await
            .map_err(|error| format!("failed to run git: {error}"))
    };
    let output = tokio::time::timeout(GIT_TIMEOUT, run).await.map_err(|_| {
        format!(
            "git {} timed out after {} seconds",
            args.first().copied().unwrap_or(""),
            GIT_TIMEOUT.as_secs()
        )
    })??;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let first = stderr.lines().next().unwrap_or("git command failed");
        return Err(first.to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn capped_lines(text: &str) -> Vec<String> {
    text.lines()
        .take(MAX_OUTPUT_LINES)
        .map(|line| line.to_string())
        .collect()
}

// ---------------------------------------------------------------------------
// Blame
// ---------------------------------------------------------------------------

#[derive(Debug, Default, PartialEq, Eq)]
struct BlameResult {
    lines: Vec<String>,
    commits: HashMap<String, CommitInfo>,
}

/// Parse `git blame --porcelain` output. The first block for a commit carries
/// the full header; later blocks for the same commit carry only the sha line,
/// which is exactly why `commits.entry(..).or_insert_with(..)` below must keep
/// the first block rather than overwrite it.  That also makes the parser
/// correct for `--line-porcelain`, where every block is a full header.
fn parse_blame(stdout: &str) -> BlameResult {
    let mut result = BlameResult::default();
    let mut sha = String::new();
    let mut author = String::new();
    let mut email = String::new();
    let mut time: i64 = 0;
    let mut summary = String::new();

    for line in stdout.lines() {
        if line.starts_with('\t') {
            // Content line terminates one header block.
            if !sha.is_empty() {
                result
                    .commits
                    .entry(sha.clone())
                    .or_insert_with(|| CommitInfo {
                        author: author.clone(),
                        email: email.clone(),
                        time,
                        summary: summary.clone(),
                    });
                result.lines.push(sha.clone());
            }
            sha.clear();
            author.clear();
            email.clear();
            time = 0;
            summary.clear();
            continue;
        }
        if let Some(value) = line.strip_prefix("author ") {
            author = value.to_string();
        } else if let Some(value) = line.strip_prefix("author-mail ") {
            email = value
                .trim()
                .trim_start_matches('<')
                .trim_end_matches('>')
                .to_string();
        } else if let Some(value) = line.strip_prefix("author-time ") {
            time = value.trim().parse().unwrap_or(0);
        } else if let Some(value) = line.strip_prefix("summary ") {
            summary = value.to_string();
        } else if sha.is_empty() {
            // Header line: "<sha> <orig> <final> [<group>]".
            let first = line.split_ascii_whitespace().next().unwrap_or("");
            if first.len() == 40 && first.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                sha = first.to_string();
            }
        }
    }
    result
}

async fn handle_blame(id: u64, path: String, tx: EventTx, _permit: OwnedSemaphorePermit) {
    let dir = file_dir(&path);
    // --porcelain repeats only the sha for a commit already described, where
    // --line-porcelain repeats the whole header block per line: on a file with
    // few distinct commits that is an order of magnitude less stdout to write,
    // read and JSON-decode on Vim's main thread.
    let result = match file_name(&path) {
        Ok(name) => run_git(&dir, &["blame", "--porcelain", "--", &name])
            .await
            .map(|stdout| parse_blame(&stdout)),
        Err(message) => Err(message),
    };
    match result {
        Ok(blame) => {
            send_event(
                &tx,
                &Event::Blame {
                    id,
                    path,
                    lines: blame.lines,
                    commits: blame.commits,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

/// Blame exactly one line.  `-L n,n` lets git stop walking history as soon as
/// that line is attributed, instead of attributing every line in the file to
/// render a single annotation.
async fn handle_blame_line(
    id: u64,
    path: String,
    lnum: u32,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let range = format!("-L{lnum},{lnum}");
    let result = match file_name(&path) {
        Ok(name) => run_git(&dir, &["blame", "--porcelain", &range, "--", &name])
            .await
            .map(|stdout| parse_blame(&stdout)),
        Err(message) => Err(message),
    };
    match result {
        Ok(blame) => {
            let sha = blame.lines.first().cloned().unwrap_or_default();
            let info = blame.commits.get(&sha).cloned().unwrap_or_default();
            send_event(
                &tx,
                &Event::BlameLine {
                    id,
                    path,
                    lnum,
                    sha,
                    author: info.author,
                    email: info.email,
                    time: info.time,
                    summary: info.summary,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

// ---------------------------------------------------------------------------
// Log
// ---------------------------------------------------------------------------

/// Parse `git log --pretty=format:%H%x1f%an%x1f%at%x1f%s` output.
fn parse_log(stdout: &str) -> Vec<LogEntry> {
    stdout
        .lines()
        .filter_map(|line| {
            let mut fields = line.split('\u{1f}');
            let sha = fields.next()?.trim();
            if sha.len() != 40 || !sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return None;
            }
            let author = fields.next()?.to_string();
            let time = fields.next()?.trim().parse().ok()?;
            let subject = fields.next().unwrap_or("").to_string();
            Some(LogEntry {
                sha: sha.to_string(),
                author,
                time,
                subject,
            })
        })
        .collect()
}

async fn handle_log(id: u64, path: String, limit: u32, tx: EventTx, _permit: OwnedSemaphorePermit) {
    let dir = file_dir(&path);
    let limit = if limit == 0 { 200 } else { limit.min(10_000) };
    let count = format!("-n{limit}");
    let result = match file_name(&path) {
        Ok(name) => {
            run_git(
                &dir,
                &[
                    "log",
                    "--follow",
                    &count,
                    "--pretty=format:%H\u{1f}%an\u{1f}%at\u{1f}%s",
                    "--",
                    &name,
                ],
            )
            .await
        }
        Err(message) => Err(message),
    };
    match result {
        Ok(stdout) => {
            send_event(
                &tx,
                &Event::Log {
                    id,
                    path,
                    entries: parse_log(&stdout),
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

/// Parse `git log --graph` output where each commit line embeds
/// `\u{1f}`-separated fields after the graph prefix.
fn parse_graph_log(stdout: &str) -> Vec<GraphRow> {
    stdout
        .lines()
        .map(|line| {
            let mut fields = line.split('\u{1f}');
            let graph = fields.next().unwrap_or("").to_string();
            match (
                fields.next(),
                fields.next(),
                fields.next(),
                fields.next(),
                fields.next(),
            ) {
                (Some(sha), Some(date), Some(author), Some(refs), Some(subject)) => GraphRow {
                    graph,
                    sha: sha.to_string(),
                    date: date.to_string(),
                    author: author.to_string(),
                    refs: refs.to_string(),
                    subject: subject.to_string(),
                },
                _ => GraphRow {
                    graph,
                    sha: String::new(),
                    date: String::new(),
                    author: String::new(),
                    refs: String::new(),
                    subject: String::new(),
                },
            }
        })
        .collect()
}

async fn handle_graph_log(
    id: u64,
    path: String,
    limit: u32,
    skip: u32,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let limit = if limit == 0 { 200 } else { limit.min(10_000) };
    let count = format!("-n{limit}");
    let skip_arg = format!("--skip={skip}");
    let result = run_git(
        &dir,
        &[
            "log",
            "--graph",
            "--date=short",
            &count,
            &skip_arg,
            "--pretty=format:\u{1f}%h\u{1f}%ad\u{1f}%an\u{1f}%D\u{1f}%s",
        ],
    )
    .await;
    match result {
        Ok(stdout) => {
            send_event(
                &tx,
                &Event::GraphLog {
                    id,
                    path,
                    skip,
                    rows: parse_graph_log(&stdout),
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

// ---------------------------------------------------------------------------
// Show / Cat
// ---------------------------------------------------------------------------

fn validate_rev(rev: &str) -> Result<(), String> {
    if rev.is_empty() || rev.len() > 256 {
        return Err("invalid revision".to_string());
    }
    // Reject values git would parse as options or that smuggle control bytes.
    if rev.starts_with('-') || rev.bytes().any(|byte| byte.is_ascii_control()) {
        return Err(format!("refusing suspicious revision: {rev}"));
    }
    Ok(())
}

async fn handle_show(
    id: u64,
    path: String,
    rev: String,
    file: Option<String>,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let result = match validate_rev(&rev) {
        Ok(()) => {
            let mut args = vec![
                "show",
                "--stat",
                "--patch",
                "--date=iso",
                "--pretty=fuller",
                rev.as_str(),
            ];
            let name;
            if let Some(ref file) = file {
                name = match file_name(file) {
                    Ok(name) => name,
                    Err(message) => {
                        send_event(&tx, &Event::Error { id, message }).await;
                        return;
                    }
                };
                args.push("--");
                args.push(&name);
            }
            run_git(&dir, &args).await
        }
        Err(message) => Err(message),
    };
    match result {
        Ok(stdout) => {
            send_event(
                &tx,
                &Event::Show {
                    id,
                    lines: capped_lines(&stdout),
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

async fn handle_cat(
    id: u64,
    path: String,
    rev: String,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let result = async {
        validate_rev(&rev)?;
        let name = file_name(&path)?;
        let prefix = run_git(&dir, &["rev-parse", "--show-prefix"]).await?;
        let spec = format!("{}:{}{}", rev, prefix.trim_end_matches('\n'), name);
        run_git(&dir, &["show", &spec]).await
    }
    .await;
    match result {
        Ok(stdout) => {
            send_event(
                &tx,
                &Event::Cat {
                    id,
                    lines: capped_lines(&stdout),
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

#[derive(Debug, Default, PartialEq, Eq)]
struct StatusResult {
    branch: String,
    /// Commits the branch is ahead of / behind its upstream. Both stay 0 when
    /// the branch has no upstream, which is also what git reports for a
    /// detached HEAD, so consumers need no separate "unknown" state.
    ahead: i64,
    behind: i64,
    entries: Vec<StatusEntry>,
}

/// Parse `git status --porcelain=v2 --branch` output into a branch name, its
/// upstream distance and a changed-file list. Rename records keep the original
/// path in `orig`.
fn parse_status(stdout: &str) -> StatusResult {
    let mut result = StatusResult::default();
    for line in stdout.lines() {
        if let Some(value) = line.strip_prefix("# branch.head ") {
            result.branch = value.trim().to_string();
        } else if let Some(value) = line.strip_prefix("# branch.ab ") {
            // "+3 -1"; the header is emitted only when an upstream is set.
            for field in value.split_ascii_whitespace() {
                match field.split_at_checked(1) {
                    Some(("+", count)) => result.ahead = count.parse().unwrap_or(0),
                    Some(("-", count)) => result.behind = count.parse().unwrap_or(0),
                    _ => {}
                }
            }
        } else if let Some(record) = line.strip_prefix("1 ") {
            // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
            let mut fields = record.splitn(8, ' ');
            let xy = fields.next().unwrap_or("").to_string();
            if let Some(path) = fields.nth(6) {
                result.entries.push(StatusEntry {
                    xy,
                    path: path.to_string(),
                    orig: None,
                });
            }
        } else if let Some(record) = line.strip_prefix("2 ") {
            // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<origPath>
            let mut fields = record.splitn(9, ' ');
            let xy = fields.next().unwrap_or("").to_string();
            if let Some(paths) = fields.nth(7) {
                let mut paths = paths.split('\t');
                let path = paths.next().unwrap_or("").to_string();
                let orig = paths.next().map(|orig| orig.to_string());
                result.entries.push(StatusEntry { xy, path, orig });
            }
        } else if let Some(record) = line.strip_prefix("u ") {
            let mut fields = record.splitn(10, ' ');
            let xy = fields.next().unwrap_or("").to_string();
            if let Some(path) = fields.nth(8) {
                result.entries.push(StatusEntry {
                    xy: format!("u{xy}"),
                    path: path.to_string(),
                    orig: None,
                });
            }
        } else if let Some(path) = line.strip_prefix("? ") {
            result.entries.push(StatusEntry {
                xy: "??".to_string(),
                path: path.to_string(),
                orig: None,
            });
        }
    }
    result
}

async fn handle_status(id: u64, path: String, tx: EventTx, _permit: OwnedSemaphorePermit) {
    let dir = file_dir(&path);
    let result = run_git(
        &dir,
        &[
            "status",
            "--porcelain=v2",
            "--branch",
            "--untracked-files=normal",
        ],
    )
    .await;
    match result {
        Ok(stdout) => {
            let status = parse_status(&stdout);
            send_event(
                &tx,
                &Event::Status {
                    id,
                    path,
                    branch: status.branch,
                    ahead: status.ahead,
                    behind: status.behind,
                    entries: status.entries,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

/// Parse `git rev-list --count --left-right <upstream>...HEAD`, which prints
/// "<behind>\t<ahead>" -- left is the upstream side.
fn parse_left_right(stdout: &str) -> (i64, i64) {
    let mut fields = stdout.split_ascii_whitespace();
    let behind = fields
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let ahead = fields
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    (ahead, behind)
}

async fn handle_branch(id: u64, path: String, tx: EventTx, _permit: OwnedSemaphorePermit) {
    let dir = file_dir(&path);
    // symbolic-ref reads one ref and nothing else; `git status --branch` would
    // walk the whole worktree for data the statusline never shows.  It is also
    // the only form that answers on an unborn branch, where `rev-parse HEAD`
    // fails outright.
    let head = match run_git(&dir, &["symbolic-ref", "--quiet", "--short", "HEAD"]).await {
        Ok(name) => name.trim().to_string(),
        // Detached HEAD: name the commit, the way git's own prompt does.
        Err(_) => match run_git(&dir, &["rev-parse", "--short", "HEAD"]).await {
            Ok(sha) => sha.trim().to_string(),
            Err(message) => {
                send_event(&tx, &Event::Error { id, message }).await;
                return;
            }
        },
    };
    // A branch without an upstream is the common case, not an error: report a
    // distance of zero rather than failing the whole summary.
    let (ahead, behind) = match run_git(
        &dir,
        &["rev-list", "--count", "--left-right", "@{upstream}...HEAD"],
    )
    .await
    {
        Ok(counts) => parse_left_right(&counts),
        Err(_) => (0, 0),
    };
    send_event(
        &tx,
        &Event::Branch {
            id,
            path,
            head,
            ahead,
            behind,
        },
    )
    .await;
}

// ---------------------------------------------------------------------------
// Hunks (working tree vs index) and hunk staging / reverting
// ---------------------------------------------------------------------------

const DIFF_ARGS: [&str; 4] = ["diff", "--no-color", "--no-ext-diff", "--unified=0"];

/// Parse one `@@ -old_start[,old_count] +new_start[,new_count] @@` header.
fn parse_hunk_header(line: &str) -> Option<(u32, u32, u32, u32)> {
    let parse_range = |text: &str| -> Option<(u32, u32)> {
        match text.split_once(',') {
            Some((start, count)) => Some((start.parse().ok()?, count.parse().ok()?)),
            None => Some((text.parse().ok()?, 1)),
        }
    };
    let rest = line.strip_prefix("@@ -")?;
    let (old_part, rest) = rest.split_once(" +")?;
    let (new_part, _) = rest.split_once(" @@")?;
    let (old_start, old_count) = parse_range(old_part)?;
    let (new_start, new_count) = parse_range(new_part)?;
    Some((old_start, old_count, new_start, new_count))
}

/// Parse `git diff -U0` output for one file into hunks. File header lines are
/// dropped; each hunk keeps its `@@` header plus body for previews.
fn parse_hunks(stdout: &str) -> Vec<Hunk> {
    let mut hunks: Vec<Hunk> = Vec::new();
    for line in stdout.lines() {
        if line.starts_with("@@ ") {
            if let Some((old_start, old_count, new_start, new_count)) = parse_hunk_header(line) {
                hunks.push(Hunk {
                    old_start,
                    old_count,
                    new_start,
                    new_count,
                    lines: vec![line.to_string()],
                });
            }
        } else if let Some(hunk) = hunks.last_mut()
            && (line.starts_with('-') || line.starts_with('+') || line.starts_with('\\'))
        {
            hunk.lines.push(line.to_string());
        }
    }
    hunks
}

/// Whether the hunk's post-image overlaps the buffer lines `first..=last`.
/// Pure deletions have no post-image lines at all, so they anchor on the line
/// the sign sits on (`new_start`, clamped to 1).
fn hunk_intersects(new_start: u32, new_count: u32, first: u32, last: u32) -> bool {
    if new_count == 0 {
        let anchor = new_start.max(1);
        anchor >= first && anchor <= last
    } else {
        new_start <= last && new_start + new_count > first
    }
}

/// Whether the hunk's post-image covers `lnum`: the one-line case of
/// `hunk_intersects`, kept so the coverage rule can be pinned on its own.
#[cfg(test)]
fn hunk_covers(new_start: u32, new_count: u32, lnum: u32) -> bool {
    hunk_intersects(new_start, new_count, lnum, lnum)
}

/// Rewrite a hunk header so a subset of a diff applies on its own. In a
/// multi-hunk diff each range is only absolute for its own side; `git apply`
/// derives insertion points from the *target* side, so rebase the other range
/// onto it. Forward application targets the index (old side), reverse the
/// working tree (new side).
///
/// `delta` is the net line growth already contributed by the kept hunks above
/// this one: the non-target side describes the file *after* those hunks land,
/// so its start slides by that much. It is zero for a lone hunk, and that is
/// the only case that existed before hunk ranges.
fn lone_hunk_header(
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    revert: bool,
    delta: i64,
) -> String {
    // The rebased side can legitimately be pushed to 0 (an insertion at the
    // top of the file is "@@ -0,0"), never below it.
    let shift = |base: u32| -> u32 { (base as i64 + delta).max(0) as u32 };
    if revert {
        let old_start = shift(if new_count == 0 {
            new_start + 1
        } else if old_count == 0 {
            new_start.saturating_sub(1)
        } else {
            new_start
        });
        format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@")
    } else {
        let new_start = shift(if old_count == 0 {
            old_start + 1
        } else if new_count == 0 {
            old_start.saturating_sub(1)
        } else {
            old_start
        });
        format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@")
    }
}

/// Build a minimal patch (file header plus every hunk whose post-image
/// overlaps buffer lines `first..=last`) from `git diff -U0` output.
///
/// The kept hunks go into one patch rather than being applied one process at a
/// time: `git apply` is all-or-nothing, so a range that cannot apply cleanly
/// leaves the index exactly as it was instead of half staged.
fn extract_hunk_patches(stdout: &str, first: u32, last: u32, revert: bool) -> Option<String> {
    let mut header: Vec<&str> = Vec::new();
    let mut kept: Vec<String> = Vec::new();
    let mut current: Vec<String> = Vec::new();
    let mut in_header = true;
    let mut keep = false;
    let mut delta: i64 = 0;
    for line in stdout.lines() {
        if line.starts_with("@@ ") {
            in_header = false;
            if keep {
                kept.append(&mut current);
            }
            current.clear();
            keep = false;
            if let Some((old_start, old_count, new_start, new_count)) = parse_hunk_header(line) {
                keep = hunk_intersects(new_start, new_count, first, last);
                if keep {
                    current.push(lone_hunk_header(
                        old_start, old_count, new_start, new_count, revert, delta,
                    ));
                    delta += if revert {
                        old_count as i64 - new_count as i64
                    } else {
                        new_count as i64 - old_count as i64
                    };
                }
            }
        } else if in_header {
            header.push(line);
        } else if keep {
            current.push(line.to_string());
        }
    }
    if keep {
        kept.append(&mut current);
    }
    if kept.is_empty() || header.is_empty() {
        return None;
    }
    let mut patch = header.join("\n");
    patch.push('\n');
    patch.push_str(&kept.join("\n"));
    patch.push('\n');
    Some(patch)
}

#[cfg(test)]
fn extract_hunk_patch(stdout: &str, lnum: u32, revert: bool) -> Option<String> {
    extract_hunk_patches(stdout, lnum, lnum, revert)
}

async fn disk_hunk_diff(path: &str) -> Result<String, String> {
    let dir = file_dir(path);
    let name = file_name(path)?;
    let mut args: Vec<&str> = DIFF_ARGS.to_vec();
    args.extend(["--", name.as_str()]);
    run_git(&dir, &args).await
}

/// Diff unsaved buffer contents against the index: materialize both sides as
/// temp files and let `git diff --no-index` produce the hunks. Exit code 1
/// just means the files differ.
/// Private scratch directory for one live diff, created with mode 0700 and
/// removed again as soon as that diff is done.
///
/// These files used to live at `$TMPDIR/simplegit-<pid>-<id>.buffer`, written
/// with plain `fs::write`: the pid is public and request ids increment, so the
/// path was predictable, `write` follows a symlink an attacker pre-created at
/// it, and on a shared /tmp the unsaved buffer contents landed in a
/// world-readable file on every keystroke burst.
///
/// The directory is per request rather than per daemon on purpose.  A daemon
/// is always stopped by a signal -- simplecore sends SIGTERM and escalates to
/// SIGKILL -- so cleanup that only runs on the way out of `main` never runs at
/// all, and a directory created once per process leaked one empty 0700
/// directory per Vim session, per `:SimpleGitRestart` and per daemon crash.
/// Creating and reaping it around the diff that needs it keeps the lifetime
/// inside the request, where it can actually be observed to happen.
fn create_scratch_dir(base: &Path) -> Result<PathBuf, String> {
    let pid = std::process::id();
    // mkdtemp by hand: the daemon has no random-number dependency, and a
    // nanosecond clock plus create()'s exclusivity is enough -- an attacker
    // who wins the guess only causes one retry, never a reused directory.
    for attempt in 0..64u32 {
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|since| since.subsec_nanos())
            .unwrap_or(0)
            ^ attempt.wrapping_mul(0x9E37_79B9);
        let candidate = base.join(format!("simplegit-{pid}-{nonce:08x}"));
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        match builder.create(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(format!("failed to create temp directory: {error}")),
        }
    }
    Err("failed to create a private temp directory".to_string())
}

/// Write one scratch file that only this user can read.  `create_new` refuses
/// an existing path, so a symlink planted at it is an error rather than a
/// write through to whatever it points at.
async fn write_private(path: &Path, contents: &str) -> Result<(), String> {
    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(path)
        .await
        .map_err(|error| format!("failed to write temp file: {error}"))?;
    file.write_all(contents.as_bytes())
        .await
        .map_err(|error| format!("failed to write temp file: {error}"))?;
    file.flush()
        .await
        .map_err(|error| format!("failed to write temp file: {error}"))
}

async fn buffer_hunk_diff(id: u64, path: &str, content: &str) -> Result<String, String> {
    buffer_hunk_diff_in(&std::env::temp_dir(), id, path, content).await
}

/// `base` is where the private scratch directory is created; only the tests
/// pass anything other than the system temp directory, so that they can assert
/// on what a live diff leaves behind without racing every other test.
async fn buffer_hunk_diff_in(
    base: &Path,
    id: u64,
    path: &str,
    content: &str,
) -> Result<String, String> {
    if content.len() > MAX_CONTENT_BYTES {
        return Err("buffer too large for a live diff".to_string());
    }
    let dir = file_dir(path);
    let name = file_name(path)?;
    let prefix = run_git(&dir, &["rev-parse", "--show-prefix"]).await?;
    let spec = format!(":{}{}", prefix.trim_end_matches('\n'), name);
    let index_text = run_git(&dir, &["show", &spec]).await?;

    let scratch = create_scratch_dir(base)?;
    let index_file = scratch.join(format!("{id}.index"));
    let buffer_file = scratch.join(format!("{id}.buffer"));
    let write = async {
        write_private(&index_file, &index_text).await?;
        write_private(&buffer_file, content).await
    }
    .await;
    let diff = match write {
        Ok(()) => {
            let mut args: Vec<&str> = DIFF_ARGS.to_vec();
            args.push("--no-index");
            args.push("--");
            let index_arg = index_file.to_string_lossy().into_owned();
            let buffer_arg = buffer_file.to_string_lossy().into_owned();
            args.push(&index_arg);
            args.push(&buffer_arg);
            run_git_coded(&dir, &args, &[1]).await
        }
        Err(message) => Err(message),
    };
    let _ = tokio::fs::remove_file(&index_file).await;
    let _ = tokio::fs::remove_file(&buffer_file).await;
    // The directory goes with them: this is the only moment at which the
    // daemon is guaranteed to still be running.
    let _ = tokio::fs::remove_dir(&scratch).await;
    diff
}

async fn handle_hunks(
    id: u64,
    path: String,
    content: Option<String>,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let result = match content {
        Some(text) => buffer_hunk_diff(id, &path, &text).await,
        None => disk_hunk_diff(&path).await,
    };
    match result {
        Ok(stdout) => {
            send_event(
                &tx,
                &Event::Hunks {
                    id,
                    path,
                    hunks: parse_hunks(&stdout),
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

async fn handle_file_op(
    id: u64,
    path: String,
    op: String,
    file: String,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let result = async {
        let args = file_op_args(&op, &file)?;
        run_git(&dir, &args).await
    }
    .await;
    match result {
        Ok(_) => send_event(&tx, &Event::FileOp { id, op, path }).await,
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

fn file_op_args<'a>(op: &str, file: &'a str) -> Result<Vec<&'a str>, String> {
    match op {
        "add" => Ok(vec!["add", "--", file]),
        "reset" => Ok(vec!["reset", "-q", "--", file]),
        // The top pathspec makes the meaning independent of the directory the
        // current buffer happens to live in. `--all` includes removals too.
        "add_all" => Ok(vec!["add", "--all", "--", ":/"]),
        "reset_all" => Ok(vec!["reset", "-q", "--", ":/"]),
        _ => Err(format!("unsupported file operation: {op}")),
    }
}

async fn handle_commit_message(id: u64, path: String, tx: EventTx, _permit: OwnedSemaphorePermit) {
    let dir = file_dir(&path);
    match run_git(&dir, &["log", "-1", "--pretty=%B"]).await {
        Ok(text) => {
            let lines = text
                .trim_end()
                .lines()
                .map(|line| line.to_string())
                .collect::<Vec<_>>();
            send_event(&tx, &Event::CommitMessage { id, path, lines }).await
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

async fn handle_commit(
    id: u64,
    path: String,
    message: String,
    amend: bool,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let result = async {
        if message.trim().is_empty() {
            return Err("empty commit message; nothing committed".to_string());
        }
        // -F - reads the message from stdin, so newlines and quotes survive
        // untouched. --cleanup=strip drops comment lines and trailing blanks
        // the same way git's own editor flow does.
        let mut args: Vec<&str> = vec!["commit", "--cleanup=strip", "-F", "-"];
        if amend {
            args.push("--amend");
        }
        let summary = run_git_with_input(&dir, &args, message).await?;

        // Report what actually landed rather than echoing back the request.
        let sha = run_git(&dir, &["rev-parse", "--short", "HEAD"])
            .await
            .unwrap_or_default()
            .trim()
            .to_string();
        let subject = run_git(&dir, &["log", "-1", "--pretty=%s"])
            .await
            .unwrap_or_default()
            .trim()
            .to_string();
        Ok((sha, subject, summary.trim().to_string()))
    }
    .await;
    match result {
        Ok((sha, subject, summary)) => {
            send_event(
                &tx,
                &Event::Commit {
                    id,
                    path,
                    sha,
                    subject,
                    summary,
                },
            )
            .await
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

async fn handle_hunk_op(
    id: u64,
    path: String,
    lnum: u32,
    last_lnum: u32,
    revert: bool,
    tx: EventTx,
    _permit: OwnedSemaphorePermit,
) {
    let dir = file_dir(&path);
    let result = async {
        let name = file_name(&path)?;
        let mut args: Vec<&str> = DIFF_ARGS.to_vec();
        args.extend(["--", name.as_str()]);
        let diff = run_git(&dir, &args).await?;
        let patch = extract_hunk_patches(&diff, lnum, last_lnum, revert).ok_or_else(|| {
            if last_lnum > lnum {
                "no hunk in the selected range".to_string()
            } else {
                "no hunk under cursor".to_string()
            }
        })?;
        // Patch paths are repository-relative; apply from the root so hunks in
        // any subdirectory resolve.
        let root = run_git(&dir, &["rev-parse", "--show-toplevel"]).await?;
        let root = PathBuf::from(root.trim_end_matches('\n'));
        let apply: &[&str] = if revert {
            &[
                "apply",
                "--reverse",
                "--unidiff-zero",
                "--whitespace=nowarn",
            ]
        } else {
            &["apply", "--cached", "--unidiff-zero", "--whitespace=nowarn"]
        };
        run_git_with_input(&root, apply, patch).await
    }
    .await;
    match result {
        Ok(_) => {
            send_event(
                &tx,
                &Event::HunkOp {
                    id,
                    action: if revert { "undo" } else { "stage" },
                    path,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
}

// ---------------------------------------------------------------------------
// Request loop
// ---------------------------------------------------------------------------

fn validate_request_path(path: &str) -> Result<(), String> {
    if path.trim().is_empty() {
        return Err("request path must not be empty".to_string());
    }
    if path.len() > MAX_REQUEST_PATH_BYTES {
        return Err(format!(
            "request path exceeds {MAX_REQUEST_PATH_BYTES} bytes"
        ));
    }
    if path.contains('\0') {
        return Err("request path must not contain NUL".to_string());
    }
    Ok(())
}

async fn report_request_completion(result: Result<(), JoinError>, tx: &EventTx) {
    if let Err(error) = result {
        send_event(
            tx,
            &Event::Error {
                id: 0,
                message: format!("git request task failed: {error}"),
            },
        )
        .await;
    }
}

async fn run_index_mutations(
    mut rx: tokio::sync::mpsc::Receiver<IndexMutation>,
    tx: EventTx,
    git_limiter: Arc<Semaphore>,
) {
    while let Some(mutation) = rx.recv().await {
        let id = mutation.id();
        let permit = match git_limiter.clone().acquire_owned().await {
            Ok(permit) => permit,
            Err(error) => {
                send_event(
                    &tx,
                    &Event::Error {
                        id,
                        message: format!("git request limiter unavailable: {error}"),
                    },
                )
                .await;
                continue;
            }
        };
        match mutation {
            IndexMutation::HunkStage {
                id,
                path,
                lnum,
                last_lnum,
            } => {
                handle_hunk_op(id, path, lnum, last_lnum, false, tx.clone(), permit).await;
            }
            IndexMutation::HunkUndo {
                id,
                path,
                lnum,
                last_lnum,
            } => {
                handle_hunk_op(id, path, lnum, last_lnum, true, tx.clone(), permit).await;
            }
            IndexMutation::FileOp { id, path, op, file } => {
                handle_file_op(id, path, op, file, tx.clone(), permit).await;
            }
            IndexMutation::Commit {
                id,
                path,
                message,
                amend,
            } => {
                handle_commit(id, path, message, amend, tx.clone(), permit).await;
            }
            #[cfg(test)]
            IndexMutation::Probe {
                id,
                delay_ms,
                observed,
            } => {
                tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                observed.lock().unwrap().push(id);
                drop(permit);
            }
        }
    }
}

fn finish_request_line(mut bytes: Vec<u8>, too_long: bool) -> Result<String, String> {
    if too_long {
        return Err(format!(
            "request line exceeds {MAX_REQUEST_LINE_BYTES} bytes"
        ));
    }
    if bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    String::from_utf8(bytes).map_err(|_| "request line is not valid UTF-8".to_string())
}

async fn read_request_line<R>(
    reader: &mut BufReader<R>,
) -> io::Result<Option<Result<String, String>>>
where
    R: AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut too_long = false;

    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if bytes.is_empty() && !too_long {
                Ok(None)
            } else {
                Ok(Some(finish_request_line(bytes, too_long)))
            };
        }

        let newline = available.iter().position(|byte| *byte == b'\n');
        let content_len = newline.unwrap_or(available.len());
        let consumed = newline.map_or(available.len(), |position| position + 1);

        if !too_long {
            if bytes.len().saturating_add(content_len) > MAX_REQUEST_LINE_BYTES {
                too_long = true;
                bytes.clear();
            } else {
                bytes.extend_from_slice(&available[..content_len]);
            }
        }
        reader.consume(consumed);

        if newline.is_some() {
            return Ok(Some(finish_request_line(bytes, too_long)));
        }
    }
}

fn request_id_and_path(req: &Request) -> (u64, Option<&str>) {
    match req {
        Request::Version { id } => (*id, None),
        Request::Blame { id, path } => (*id, Some(path)),
        Request::BlameLine { id, path, .. } => (*id, Some(path)),
        Request::Log { id, path, .. } => (*id, Some(path)),
        Request::GraphLog { id, path, .. } => (*id, Some(path)),
        Request::Show { id, path, .. } => (*id, Some(path)),
        Request::Cat { id, path, .. } => (*id, Some(path)),
        Request::Status { id, path } => (*id, Some(path)),
        Request::Branch { id, path } => (*id, Some(path)),
        Request::Hunks { id, path, .. } => (*id, Some(path)),
        Request::Stage { id, path, .. } => (*id, Some(path)),
        Request::Undo { id, path, .. } => (*id, Some(path)),
        Request::FileOp { id, path, .. } => (*id, Some(path)),
        Request::Commit { id, path, .. } => (*id, Some(path)),
        Request::CommitMessage { id, path } => (*id, Some(path)),
    }
}

async fn run<R, W>(input: R, output: W) -> io::Result<()>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut input = BufReader::new(input);

    let (out_tx, out_rx) = tokio::sync::mpsc::channel::<String>(1024);
    let writer = tokio::spawn(stdout_writer(output, out_rx));
    let git_limiter = Arc::new(Semaphore::new(MAX_CONCURRENT_GIT_REQUESTS));
    let (index_tx, index_rx) =
        tokio::sync::mpsc::channel::<IndexMutation>(MAX_PENDING_INDEX_MUTATIONS);
    let index_worker = tokio::spawn(run_index_mutations(
        index_rx,
        out_tx.clone(),
        git_limiter.clone(),
    ));
    let mut requests = JoinSet::new();
    let mut input_error = None;

    loop {
        let line = match read_request_line(&mut input).await {
            Ok(Some(line)) => line,
            Ok(None) => break,
            Err(error) => {
                input_error = Some(error);
                break;
            }
        };
        while let Some(result) = requests.try_join_next() {
            report_request_completion(result, &out_tx).await;
        }

        let line = match line {
            Ok(line) => line,
            Err(message) => {
                send_event(&out_tx, &Event::Error { id: 0, message }).await;
                continue;
            }
        };
        if line.trim().is_empty() {
            continue;
        }

        let req = match serde_json::from_str::<Request>(&line) {
            Ok(req) => req,
            Err(error) => {
                send_event(
                    &out_tx,
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {error}"),
                    },
                )
                .await;
                continue;
            }
        };

        let (id, path) = request_id_and_path(&req);
        if let Some(path) = path
            && let Err(message) = validate_request_path(path)
        {
            send_event(&out_tx, &Event::Error { id, message }).await;
            continue;
        }

        match req {
            Request::Version { id } => {
                send_event(
                    &out_tx,
                    &Event::Version {
                        id,
                        version: env!("CARGO_PKG_VERSION"),
                        protocol: PROTOCOL_VERSION,
                        capabilities: protocol_capabilities(),
                    },
                )
                .await;
            }
            Request::Blame { id, path } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_blame(id, path, tx, permit));
            }
            Request::BlameLine { id, path, lnum } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_blame_line(id, path, lnum, tx, permit));
            }
            Request::Log { id, path, limit } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_log(id, path, limit, tx, permit));
            }
            Request::GraphLog {
                id,
                path,
                limit,
                skip,
            } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_graph_log(id, path, limit, skip, tx, permit));
            }
            Request::Show {
                id,
                path,
                rev,
                file,
            } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_show(id, path, rev, file, tx, permit));
            }
            Request::Cat { id, path, rev } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_cat(id, path, rev, tx, permit));
            }
            Request::Status { id, path } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_status(id, path, tx, permit));
            }
            Request::Branch { id, path } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_branch(id, path, tx, permit));
            }
            Request::Hunks { id, path, content } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_hunks(id, path, content, tx, permit));
            }
            Request::Stage {
                id,
                path,
                lnum,
                last_lnum,
            } => {
                let last_lnum = last_lnum.unwrap_or(lnum).max(lnum);
                if index_tx
                    .send(IndexMutation::HunkStage {
                        id,
                        path,
                        lnum,
                        last_lnum,
                    })
                    .await
                    .is_err()
                {
                    send_event(
                        &out_tx,
                        &Event::Error {
                            id,
                            message: "index mutation queue unavailable".to_string(),
                        },
                    )
                    .await;
                }
            }
            Request::Undo {
                id,
                path,
                lnum,
                last_lnum,
            } => {
                let last_lnum = last_lnum.unwrap_or(lnum).max(lnum);
                if index_tx
                    .send(IndexMutation::HunkUndo {
                        id,
                        path,
                        lnum,
                        last_lnum,
                    })
                    .await
                    .is_err()
                {
                    send_event(
                        &out_tx,
                        &Event::Error {
                            id,
                            message: "index mutation queue unavailable".to_string(),
                        },
                    )
                    .await;
                }
            }
            Request::FileOp { id, path, op, file } => {
                if let Err(message) = validate_request_path(&file) {
                    send_event(&out_tx, &Event::Error { id, message }).await;
                    continue;
                }
                if index_tx
                    .send(IndexMutation::FileOp { id, path, op, file })
                    .await
                    .is_err()
                {
                    send_event(
                        &out_tx,
                        &Event::Error {
                            id,
                            message: "index mutation queue unavailable".to_string(),
                        },
                    )
                    .await;
                }
            }
            Request::CommitMessage { id, path } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_commit_message(id, path, tx, permit));
            }
            Request::Commit {
                id,
                path,
                message,
                amend,
            } => {
                if index_tx
                    .send(IndexMutation::Commit {
                        id,
                        path,
                        message,
                        amend,
                    })
                    .await
                    .is_err()
                {
                    send_event(
                        &out_tx,
                        &Event::Error {
                            id,
                            message: "index mutation queue unavailable".to_string(),
                        },
                    )
                    .await;
                }
            }
        }
    }

    drop(index_tx);
    report_request_completion(index_worker.await, &out_tx).await;
    while let Some(result) = requests.join_next().await {
        report_request_completion(result, &out_tx).await;
    }
    drop(out_tx);
    let _ = writer.await;
    match input_error {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

const USAGE: &str = "\
Usage: simplegit-daemon [OPTION]

With no arguments the daemon serves newline-delimited JSON requests on stdin
and writes replies to stdout.  That is how the Vim plugin starts it; there is
nothing useful to do with it interactively.

Options:
  -V, --version    print the version and exit
  -h, --help       print this help and exit
      --self-test  run one request through the daemon in-process and exit
";

/// Drives a real request through [`run`] over in-memory pipes.
///
/// The installer needs to know that the binary it just built actually works,
/// and a version string only proves the file is not corrupt.  This exercises
/// the parse → dispatch → reply path that every request takes.
async fn self_test() -> Result<(), String> {
    use tokio::io::AsyncReadExt;

    let request = format!("{}\n", serde_json::json!({"id": 1, "type": "version"}));

    // `run` spawns its writer task, so the sink has to be owned and 'static —
    // a borrowed Vec will not do.  A duplex pipe gives an owned write half;
    // run drops it on the way out, which is what ends the read below.
    let (mut client, server) = tokio::io::duplex(64 * 1024);
    run(request.as_bytes(), server)
        .await
        .map_err(|error| format!("daemon loop failed: {error}"))?;

    let mut reply = String::new();
    client
        .read_to_string(&mut reply)
        .await
        .map_err(|error| format!("could not read the reply: {error}"))?;
    let first = reply
        .lines()
        .next()
        .ok_or_else(|| "daemon produced no reply".to_string())?;
    let parsed: serde_json::Value =
        serde_json::from_str(first).map_err(|error| format!("reply was not JSON: {error}"))?;

    match parsed.get("protocol").and_then(serde_json::Value::as_u64) {
        Some(version) if version == u64::from(PROTOCOL_VERSION) => Ok(()),
        Some(version) => Err(format!(
            "daemon announced protocol {version}, this build is {PROTOCOL_VERSION}"
        )),
        None => Err(format!("reply carried no protocol version: {first}")),
    }
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => {
            let result = run(io::stdin(), io::stdout()).await;
            match result {
                Ok(()) => std::process::ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("simplegit-daemon: {error}");
                    std::process::ExitCode::FAILURE
                }
            }
        }
        Some("--version" | "-V") => {
            println!("simplegit-daemon {}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--help" | "-h") => {
            println!("simplegit-daemon {}\n\n{USAGE}", env!("CARGO_PKG_VERSION"));
            std::process::ExitCode::SUCCESS
        }
        Some("--self-test") => match self_test().await {
            Ok(()) => {
                println!("ok");
                std::process::ExitCode::SUCCESS
            }
            Err(message) => {
                eprintln!("self-test failed: {message}");
                std::process::ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("unknown argument: {other}\n\n{USAGE}");
            std::process::ExitCode::from(2)
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const UNCOMMITTED_SHA: &str = "0000000000000000000000000000000000000000";

    struct ErrorAfterInput {
        bytes: Vec<u8>,
        position: usize,
        errored: bool,
    }

    impl AsyncRead for ErrorAfterInput {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<io::Result<()>> {
            if self.position < self.bytes.len() {
                let start = self.position;
                let count = buf.remaining().min(self.bytes.len() - start);
                buf.put_slice(&self.bytes[start..start + count]);
                self.position += count;
                return std::task::Poll::Ready(Ok(()));
            }
            if !self.errored {
                self.errored = true;
                return std::task::Poll::Ready(Err(io::Error::other("injected input failure")));
            }
            std::task::Poll::Ready(Ok(()))
        }
    }

    #[test]
    fn blame_line_porcelain_is_parsed() {
        let sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let stdout = format!(
            "{sha_a} 1 1 2\n\
             author Alice\n\
             author-mail <alice@example.com>\n\
             author-time 1700000000\n\
             author-tz +0000\n\
             summary first commit\n\
             filename foo.txt\n\
             \tline one\n\
             {sha_a} 2 2\n\
             author Alice\n\
             author-time 1700000000\n\
             summary first commit\n\
             filename foo.txt\n\
             \tline two\n\
             {sha_b} 1 3 1\n\
             author Bob\n\
             author-time 1710000000\n\
             summary second commit\n\
             filename foo.txt\n\
             \tline three\n"
        );
        let result = parse_blame(&stdout);
        assert_eq!(result.lines, vec![sha_a, sha_a, sha_b]);
        assert_eq!(result.commits.len(), 2);
        assert_eq!(result.commits[sha_a].author, "Alice");
        assert_eq!(result.commits[sha_a].email, "alice@example.com");
        assert_eq!(result.commits[sha_a].time, 1_700_000_000);
        assert_eq!(result.commits[sha_b].summary, "second commit");
    }

    /// Plain `--porcelain` -- what both blame paths now request -- emits the
    /// header block only for the first line of a commit; every later line of
    /// the same commit is a bare sha line followed by its content.  Nothing
    /// pinned that before, and it is precisely what makes the switch away from
    /// --line-porcelain safe.
    /// The live diff writes the unsaved buffer to disk to hand it to
    /// `git diff --no-index`.  That file must be unreadable by anyone else and
    /// must never be an attacker's symlink to somewhere interesting.
    #[cfg(unix)]
    #[tokio::test]
    async fn live_diff_scratch_files_are_private() {
        use std::os::unix::fs::PermissionsExt;

        let base = temp_fixture_dir("scratch-private");
        let dir = create_scratch_dir(&base).expect("scratch directory");
        let mode = std::fs::metadata(&dir)
            .expect("scratch directory exists")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o700, "scratch directory is private");

        let file = dir.join("private-probe");
        write_private(&file, "unsaved buffer contents")
            .await
            .expect("write");
        let mode = std::fs::metadata(&file)
            .expect("scratch file exists")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "scratch file is owner-only");
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "unsaved buffer contents"
        );
        std::fs::remove_file(&file).unwrap();

        // A path that already exists -- here a symlink, the interesting case --
        // is refused rather than followed and truncated.
        let target = dir.join("target");
        std::fs::write(&target, "do not clobber me").unwrap();
        let link = dir.join("symlink-probe");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(
            write_private(&link, "attacker payload").await.is_err(),
            "an existing path must not be written through"
        );
        assert_eq!(
            std::fs::read_to_string(&target).unwrap(),
            "do not clobber me"
        );
        std::fs::remove_file(&link).unwrap();
        std::fs::remove_file(&target).unwrap();
        std::fs::remove_dir_all(&base).unwrap();
    }

    /// A live diff must leave nothing behind.  Cleanup used to sit on the
    /// normal return path of `main`, which a daemon never reaches: simplecore
    /// stops it with SIGTERM and escalates to SIGKILL, so every daemon that had
    /// ever served a live diff leaked one empty 0700 directory -- one per Vim
    /// session, per `:SimpleGitRestart` and per crash-restart.  The lifetime
    /// now belongs to the request, which is the only moment the process is
    /// certainly still alive.
    #[tokio::test]
    async fn live_diff_leaves_no_scratch_directory_behind() {
        use std::process::Command;

        if Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let repo = temp_fixture_dir("scratch-reap-repo");
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        git(&["init", "-q"]);
        git(&["config", "user.email", "test@example.com"]);
        git(&["config", "user.name", "Test"]);
        std::fs::write(repo.join("sample.txt"), "before\n").unwrap();
        git(&["add", "sample.txt"]);

        let base = temp_fixture_dir("scratch-reap-base");
        let file = repo.join("sample.txt");
        let diff = buffer_hunk_diff_in(&base, 7, &file.to_string_lossy(), "after\n")
            .await
            .expect("live diff against the index");
        assert!(
            diff.contains("+after"),
            "the live diff still reports the unsaved change: {diff}"
        );
        let leftovers: Vec<String> = std::fs::read_dir(&base)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            leftovers.is_empty(),
            "the live diff left {leftovers:?} behind"
        );

        std::fs::remove_dir_all(&base).unwrap();
        std::fs::remove_dir_all(&repo).unwrap();
    }

    /// A private directory under the system temp directory, named so that a
    /// failed run is traceable to the test that made it.
    fn temp_fixture_dir(label: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir =
            std::env::temp_dir().join(format!("simplegit-{label}-{}-{nonce}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn blame_porcelain_repeats_only_the_sha() {
        let sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        let stdout = format!(
            "{sha_a} 1 1 2\n\
             author Alice\n\
             author-mail <alice@example.com>\n\
             author-time 1700000000\n\
             summary first commit\n\
             filename foo.txt\n\
             \tline one\n\
             {sha_a} 2 2\n\
             \tline two\n\
             {sha_b} 3 3 1\n\
             author Bob\n\
             author-mail <bob@example.com>\n\
             author-time 1710000000\n\
             summary second commit\n\
             filename foo.txt\n\
             \tline three\n\
             {sha_a} 4 4\n\
             \tline four\n"
        );
        let result = parse_blame(&stdout);
        assert_eq!(result.lines, vec![sha_a, sha_a, sha_b, sha_a]);
        // The abbreviated repeats must reuse the first block, not blank it out.
        assert_eq!(result.commits.len(), 2);
        assert_eq!(result.commits[sha_a].author, "Alice");
        assert_eq!(result.commits[sha_a].email, "alice@example.com");
        assert_eq!(result.commits[sha_a].summary, "first commit");
        assert_eq!(result.commits[sha_a].time, 1_700_000_000);
        assert_eq!(result.commits[sha_b].author, "Bob");
    }

    /// `git blame --porcelain -L n,n` returns a single block; the daemon
    /// reports it as one commit rather than a whole-file map.
    #[test]
    fn blame_of_one_line_yields_one_commit() {
        let sha = "cccccccccccccccccccccccccccccccccccccccc";
        let stdout = format!(
            "{sha} 42 42 1\n\
             author Carol\n\
             author-mail <carol@example.com>\n\
             author-time 1720000000\n\
             summary only this line\n\
             filename foo.txt\n\
             \tthe line itself\n"
        );
        let result = parse_blame(&stdout);
        assert_eq!(result.lines, vec![sha]);
        assert_eq!(result.commits[sha].author, "Carol");
        assert_eq!(result.commits[sha].email, "carol@example.com");
        assert_eq!(result.commits[sha].summary, "only this line");
    }

    #[test]
    fn blame_uncommitted_lines_use_zero_sha() {
        let stdout = format!(
            "{UNCOMMITTED_SHA} 1 1 1\n\
             author Not Committed Yet\n\
             author-time 1700000000\n\
             summary Version of foo.txt from foo.txt\n\
             filename foo.txt\n\
             \tdirty line\n"
        );
        let result = parse_blame(&stdout);
        assert_eq!(result.lines, vec![UNCOMMITTED_SHA]);
    }

    #[test]
    fn log_entries_are_parsed_and_garbage_skipped() {
        let sha = "cccccccccccccccccccccccccccccccccccccccc";
        let stdout = format!("{sha}\u{1f}Carol\u{1f}1720000000\u{1f}fix: subject\nnot-a-line\n");
        let entries = parse_log(&stdout);
        assert_eq!(
            entries,
            vec![LogEntry {
                sha: sha.to_string(),
                author: "Carol".to_string(),
                time: 1_720_000_000,
                subject: "fix: subject".to_string(),
            }]
        );
    }

    #[test]
    fn status_v2_records_are_parsed() {
        let stdout = "\
# branch.oid deadbeef\n\
# branch.head main\n\
1 .M N... 100644 100644 100644 aaaa bbbb src/lib.rs\n\
2 R. N... 100644 100644 100644 aaaa bbbb R100 new name.txt\told name.txt\n\
u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflict.rs\n\
? untracked file.txt\n";
        let result = parse_status(stdout);
        assert_eq!(result.branch, "main");
        assert_eq!(result.entries.len(), 4);
        // No `# branch.ab` header: no upstream, not "unknown".
        assert_eq!((result.ahead, result.behind), (0, 0));
        assert_eq!(result.entries[0].xy, ".M");
        assert_eq!(result.entries[0].path, "src/lib.rs");
        assert_eq!(result.entries[1].path, "new name.txt");
        assert_eq!(result.entries[1].orig.as_deref(), Some("old name.txt"));
        assert_eq!(result.entries[2].xy, "uUU");
        assert_eq!(result.entries[2].path, "conflict.rs");
        assert_eq!(result.entries[3].xy, "??");
        assert_eq!(result.entries[3].path, "untracked file.txt");
    }

    #[test]
    fn status_reports_upstream_distance() {
        let stdout = "\
# branch.oid deadbeef\n\
# branch.head feature\n\
# branch.upstream origin/feature\n\
# branch.ab +12 -3\n\
1 .M N... 100644 100644 100644 aaaa bbbb src/lib.rs\n";
        let result = parse_status(stdout);
        assert_eq!(result.branch, "feature");
        assert_eq!((result.ahead, result.behind), (12, 3));
        assert_eq!(result.entries.len(), 1);

        // A malformed count must not poison the rest of the header.
        let broken = "# branch.head main\n# branch.ab +x -2\n";
        let result = parse_status(broken);
        assert_eq!((result.ahead, result.behind), (0, 2));
    }

    #[test]
    fn file_operations_distinguish_one_file_from_the_repository() {
        assert_eq!(
            file_op_args("add", "dir/file.txt").unwrap(),
            vec!["add", "--", "dir/file.txt"]
        );
        assert_eq!(
            file_op_args("reset", "dir/file.txt").unwrap(),
            vec!["reset", "-q", "--", "dir/file.txt"]
        );
        assert_eq!(
            file_op_args("add_all", ".").unwrap(),
            vec!["add", "--all", "--", ":/"]
        );
        assert_eq!(
            file_op_args("reset_all", ".").unwrap(),
            vec!["reset", "-q", "--", ":/"]
        );
        assert!(file_op_args("remove", "file.txt").is_err());
    }

    #[test]
    fn suspicious_revisions_are_rejected() {
        assert!(validate_rev("HEAD").is_ok());
        assert!(validate_rev("main~3").is_ok());
        assert!(validate_rev("--upload-pack=evil").is_err());
        assert!(validate_rev("a\nb").is_err());
        assert!(validate_rev("").is_err());
    }

    #[tokio::test]
    async fn version_handshake_round_trips() {
        let input = b"{\"type\":\"version\",\"id\":0}\n".to_vec();
        let (client, server) = tokio::io::duplex(64 * 1024);
        let (mut client_read, mut client_write) = tokio::io::split(client);
        let (server_read, server_write) = tokio::io::split(server);
        let daemon = tokio::spawn(run(server_read, server_write));
        client_write.write_all(&input).await.unwrap();
        // Dropping a split write half does not close the duplex stream; an
        // explicit shutdown is what delivers EOF to the daemon.
        client_write.shutdown().await.unwrap();
        drop(client_write);
        let mut response = String::new();
        tokio::io::AsyncReadExt::read_to_string(&mut client_read, &mut response)
            .await
            .unwrap();
        daemon.await.unwrap().unwrap();
        assert!(response.contains("\"type\":\"version\""));
        assert!(response.contains("\"protocol\":5"));
        let version: serde_json::Value =
            serde_json::from_str(response.lines().next().unwrap()).expect("version reply is JSON");
        assert_eq!(
            version["capabilities"][CAP_REPOSITORY_FILE_OPS],
            serde_json::Value::Bool(true)
        );
        assert_eq!(
            version["capabilities"][CAP_BRANCH_SUMMARY],
            serde_json::Value::Bool(true)
        );
        assert_eq!(
            version["capabilities"][CAP_BLAME_LINE],
            serde_json::Value::Bool(true)
        );
        assert_eq!(
            version["capabilities"][CAP_HUNK_RANGE],
            serde_json::Value::Bool(true)
        );
    }

    #[test]
    fn upstream_distance_reads_left_as_behind() {
        // git prints the left side -- the upstream -- first.
        assert_eq!(parse_left_right("3\t7\n"), (7, 3));
        assert_eq!(parse_left_right("0\t0\n"), (0, 0));
        // Without an upstream git fails and the parser is never reached, but a
        // truncated or malformed line must still not panic.
        assert_eq!(parse_left_right(""), (0, 0));
        assert_eq!(parse_left_right("x\ty"), (0, 0));
    }

    #[tokio::test]
    async fn input_errors_drain_queued_index_operations_before_returning() {
        use tokio::io::AsyncReadExt;

        let request = serde_json::json!({
            "type": "file_op", "id": 77, "path": ".",
            "op": "unsupported", "file": "sample.txt"
        })
        .to_string()
            + "\n";
        let input = ErrorAfterInput {
            bytes: request.into_bytes(),
            position: 0,
            errored: false,
        };
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        let error = run(input, server).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Other);

        let mut response = String::new();
        client.read_to_string(&mut response).await.unwrap();
        let reply: serde_json::Value = serde_json::from_str(response.trim()).unwrap();
        assert_eq!(reply["id"], 77);
        assert!(
            reply["message"]
                .as_str()
                .unwrap()
                .contains("unsupported file operation")
        );
    }

    #[tokio::test]
    async fn index_mutations_execute_in_fifo_order() {
        let (queue_tx, queue_rx) = tokio::sync::mpsc::channel(4);
        let (event_tx, _event_rx) = tokio::sync::mpsc::channel(4);
        let observed = Arc::new(std::sync::Mutex::new(Vec::new()));

        queue_tx
            .send(IndexMutation::Probe {
                id: 1,
                delay_ms: 40,
                observed: observed.clone(),
            })
            .await
            .unwrap();
        queue_tx
            .send(IndexMutation::Probe {
                id: 2,
                delay_ms: 0,
                observed: observed.clone(),
            })
            .await
            .unwrap();
        drop(queue_tx);

        run_index_mutations(
            queue_rx,
            event_tx,
            Arc::new(Semaphore::new(MAX_CONCURRENT_GIT_REQUESTS)),
        )
        .await;
        assert_eq!(*observed.lock().unwrap(), vec![1, 2]);
    }

    #[tokio::test]
    async fn burst_file_mutations_preserve_request_order() {
        use std::process::Command;
        use std::time::{SystemTime, UNIX_EPOCH};
        use tokio::io::AsyncReadExt;

        if Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let repo = std::env::temp_dir().join(format!(
            "simplegit-index-fifo-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&repo).unwrap();
        let git = |args: &[&str]| {
            let output = Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        };
        git(&["init", "-q"]);
        git(&["config", "user.email", "test@example.com"]);
        git(&["config", "user.name", "Test"]);
        git(&["config", "commit.gpgsign", "false"]);
        std::fs::write(repo.join("sample.txt"), "before\n").unwrap();
        git(&["add", "sample.txt"]);
        git(&["commit", "-q", "-m", "initial"]);
        std::fs::write(repo.join("sample.txt"), "after\n").unwrap();

        // Do not wait for add before sending reset.  Concurrent handlers used
        // to race on index.lock and could leave either final state; the FIFO
        // lane must answer in input order and leave the second operation last.
        let input = format!(
            "{}\n{}\n",
            serde_json::json!({
                "type": "file_op", "id": 41, "path": repo,
                "op": "add", "file": "sample.txt"
            }),
            serde_json::json!({
                "type": "file_op", "id": 42, "path": repo,
                "op": "reset", "file": "sample.txt"
            })
        );
        let (mut client, server) = tokio::io::duplex(64 * 1024);
        run(input.as_bytes(), server).await.unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).await.unwrap();
        let replies = response
            .lines()
            .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            replies
                .iter()
                .map(|reply| reply["id"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            vec![41, 42]
        );
        git(&["diff", "--cached", "--quiet"]);
        std::fs::remove_dir_all(repo).unwrap();
    }

    const DIFF_FIXTURE: &str = "\
diff --git a/src/lib.rs b/src/lib.rs\n\
index aaaa111..bbbb222 100644\n\
--- a/src/lib.rs\n\
+++ b/src/lib.rs\n\
@@ -3 +3 @@ fn top()\n\
-old line\n\
+new line\n\
@@ -10,0 +11,2 @@ fn mid()\n\
+added one\n\
+added two\n\
@@ -20,3 +22,0 @@ fn tail()\n\
-gone one\n\
-gone two\n\
-gone three\n";

    #[test]
    fn hunk_headers_are_parsed() {
        assert_eq!(parse_hunk_header("@@ -3 +3 @@ fn x()"), Some((3, 1, 3, 1)));
        assert_eq!(parse_hunk_header("@@ -10,0 +11,2 @@"), Some((10, 0, 11, 2)));
        assert_eq!(parse_hunk_header("@@ -20,3 +22,0 @@"), Some((20, 3, 22, 0)));
        assert_eq!(parse_hunk_header("@@ garbage"), None);
        assert_eq!(parse_hunk_header("not a header"), None);
    }

    #[test]
    fn diff_hunks_are_parsed() {
        let hunks = parse_hunks(DIFF_FIXTURE);
        assert_eq!(hunks.len(), 3);
        assert_eq!((hunks[0].old_start, hunks[0].old_count), (3, 1));
        assert_eq!((hunks[0].new_start, hunks[0].new_count), (3, 1));
        assert_eq!(hunks[0].lines.len(), 3);
        assert_eq!(
            hunks[1].lines,
            vec!["@@ -10,0 +11,2 @@ fn mid()", "+added one", "+added two"]
        );
        assert_eq!((hunks[2].new_start, hunks[2].new_count), (22, 0));
    }

    #[test]
    fn hunk_coverage_handles_deletions() {
        assert!(hunk_covers(3, 1, 3));
        assert!(!hunk_covers(3, 1, 4));
        assert!(hunk_covers(11, 2, 12));
        assert!(!hunk_covers(11, 2, 13));
        // Pure deletion anchors on new_start, clamped to line 1.
        assert!(hunk_covers(22, 0, 22));
        assert!(!hunk_covers(22, 0, 21));
        assert!(hunk_covers(0, 0, 1));
    }

    #[test]
    fn hunk_patch_is_extracted_with_file_header() {
        let patch = extract_hunk_patch(DIFF_FIXTURE, 11, false).unwrap();
        assert!(patch.starts_with("diff --git a/src/lib.rs b/src/lib.rs\n"));
        assert!(patch.contains("+++ b/src/lib.rs\n"));
        assert!(patch.contains("@@ -10,0 +11,2 @@"));
        assert!(patch.contains("+added one\n+added two\n"));
        assert!(!patch.contains("old line"));
        assert!(!patch.contains("gone one"));
        assert!(extract_hunk_patch(DIFF_FIXTURE, 5, false).is_none());
        assert!(extract_hunk_patch("", 1, false).is_none());
    }

    #[test]
    fn lone_hunk_headers_rebase_on_the_target_side() {
        // Forward (stage): the old range is absolute for the index.
        assert_eq!(lone_hunk_header(3, 1, 5, 1, false, 0), "@@ -3,1 +3,1 @@");
        assert_eq!(
            lone_hunk_header(10, 0, 11, 2, false, 0),
            "@@ -10,0 +11,2 @@"
        );
        assert_eq!(
            lone_hunk_header(20, 3, 22, 0, false, 0),
            "@@ -20,3 +19,0 @@"
        );
        assert_eq!(lone_hunk_header(0, 0, 1, 2, false, 0), "@@ -0,0 +1,2 @@");
        // Reverse (undo): the new range is absolute for the working tree.
        assert_eq!(lone_hunk_header(3, 1, 5, 1, true, 0), "@@ -5,1 +5,1 @@");
        assert_eq!(lone_hunk_header(10, 0, 11, 2, true, 0), "@@ -10,0 +11,2 @@");
        assert_eq!(lone_hunk_header(20, 3, 22, 0, true, 0), "@@ -23,3 +22,0 @@");
        // The staged '+seven' regression: insertion extracted after a net -1
        // earlier hunk must land after old line 6, not before it.
        assert_eq!(lone_hunk_header(6, 0, 6, 1, false, 0), "@@ -6,0 +7,1 @@");
        // With earlier hunks of the same patch kept, the rebased side slides by
        // their net growth: two lines added above move this one down by two.
        assert_eq!(
            lone_hunk_header(20, 1, 22, 1, false, 2),
            "@@ -20,1 +22,1 @@"
        );
        assert_eq!(
            lone_hunk_header(20, 3, 22, 0, false, -1),
            "@@ -20,3 +18,0 @@"
        );
        assert_eq!(
            lone_hunk_header(20, 1, 22, 1, true, -2),
            "@@ -20,1 +22,1 @@"
        );
        // A delta can never push a start below zero.
        assert_eq!(lone_hunk_header(1, 1, 1, 1, false, -9), "@@ -1,1 +0,1 @@");
    }

    #[test]
    fn a_range_keeps_every_overlapping_hunk_in_one_patch() {
        // Lines 3..12 overlap the first two hunks and not the deletion at 22.
        let patch = extract_hunk_patches(DIFF_FIXTURE, 3, 12, false).unwrap();
        assert!(patch.starts_with("diff --git a/src/lib.rs b/src/lib.rs\n"));
        assert!(patch.contains("-old line\n+new line\n"));
        assert!(patch.contains("+added one\n+added two\n"));
        assert!(!patch.contains("gone one"));
        // The first hunk is line-neutral, so the second is not displaced.
        assert!(patch.contains("@@ -3,1 +3,1 @@"));
        assert!(patch.contains("@@ -10,0 +11,2 @@"));

        // The whole file: the deletion now follows a +2 insertion, so on the
        // index side it lands two lines further down than it would alone.
        let patch = extract_hunk_patches(DIFF_FIXTURE, 1, 100, false).unwrap();
        assert!(patch.contains("@@ -20,3 +21,0 @@"));
        assert_eq!(patch.matches("@@ -").count(), 3);

        // Reverting the same range rebases the other side instead: the
        // deletion is restored after the +2 insertion has been taken away.
        let patch = extract_hunk_patches(DIFF_FIXTURE, 1, 100, true).unwrap();
        assert!(patch.contains("@@ -3,1 +3,1 @@"));
        assert!(patch.contains("@@ -10,0 +11,2 @@"));
        assert!(patch.contains("@@ -21,3 +22,0 @@"));

        // A range that touches no hunk yields no patch at all, so nothing is
        // applied -- rather than a header-only patch git would reject.
        assert!(extract_hunk_patches(DIFF_FIXTURE, 4, 9, false).is_none());
        // A pure deletion is reachable only through its anchor line.
        assert!(extract_hunk_patches(DIFF_FIXTURE, 22, 22, false).is_some());
        assert!(extract_hunk_patches(DIFF_FIXTURE, 23, 40, false).is_none());
    }

    #[test]
    fn parse_graph_log_splits_commit_and_connector_rows() {
        let sep = '\u{1f}';
        let stdout = format!(
            "* {sep}abc1234{sep}2026-07-26{sep}Alice{sep}HEAD -> main, origin/main{sep}Subject one\n\
             | * {sep}def5678{sep}2026-07-25{sep}Bob{sep}{sep}feature: two\n\
             |/\n\
             * {sep}0011223{sep}2026-07-24{sep}Carol{sep}tag: v1.0{sep}three\n"
        );
        let rows = parse_graph_log(&stdout);
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].graph, "* ");
        assert_eq!(rows[0].sha, "abc1234");
        assert_eq!(rows[0].refs, "HEAD -> main, origin/main");
        assert_eq!(rows[0].subject, "Subject one");
        assert_eq!(rows[1].graph, "| * ");
        assert_eq!(rows[1].refs, "");
        // Connector-only line carries the graph text and nothing else.
        assert_eq!(rows[2].graph, "|/");
        assert_eq!(rows[2].sha, "");
        assert_eq!(rows[3].date, "2026-07-24");
        assert_eq!(rows[3].refs, "tag: v1.0");
    }

    #[test]
    fn parse_graph_log_ignores_malformed_field_counts() {
        // Fewer than five fields after the graph prefix must degrade to a
        // connector row instead of misaligning columns.
        let stdout = "* \u{1f}abc1234\u{1f}2026-07-26\n";
        let rows = parse_graph_log(stdout);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].sha, "");
        assert_eq!(rows[0].graph, "* ");
    }
}

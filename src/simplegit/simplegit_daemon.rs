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
const PROTOCOL_VERSION: u32 = 5;
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
    /// Per-line blame for one file on disk.
    #[serde(rename = "blame")]
    Blame { id: u64, path: String },
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
    /// Stage the hunk covering line `lnum` (`git apply --cached`).
    #[serde(rename = "stage")]
    Stage { id: u64, path: String, lnum: u32 },
    /// Revert the hunk covering line `lnum` in the working tree.
    #[serde(rename = "undo")]
    Undo { id: u64, path: String, lnum: u32 },
    /// Stage or unstage a whole file: op is "add" or "reset".
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

#[derive(Debug, Serialize, Clone, PartialEq, Eq)]
struct CommitInfo {
    author: String,
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
    },
    #[serde(rename = "blame")]
    Blame {
        id: u64,
        path: String,
        lines: Vec<String>,
        commits: HashMap<String, CommitInfo>,
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
        entries: Vec<StatusEntry>,
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

/// Parse `git blame --line-porcelain` output. Every output line carries the
/// full header block, so the parser only needs the fields it displays.
fn parse_blame(stdout: &str) -> BlameResult {
    let mut result = BlameResult::default();
    let mut sha = String::new();
    let mut author = String::new();
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
                        time,
                        summary: summary.clone(),
                    });
                result.lines.push(sha.clone());
            }
            sha.clear();
            author.clear();
            time = 0;
            summary.clear();
            continue;
        }
        if let Some(value) = line.strip_prefix("author ") {
            author = value.to_string();
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
    let result = match file_name(&path) {
        Ok(name) => run_git(&dir, &["blame", "--line-porcelain", "--", &name])
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
    entries: Vec<StatusEntry>,
}

/// Parse `git status --porcelain=v2 --branch` output into a branch name and a
/// changed-file list. Rename records keep the original path in `orig`.
fn parse_status(stdout: &str) -> StatusResult {
    let mut result = StatusResult::default();
    for line in stdout.lines() {
        if let Some(value) = line.strip_prefix("# branch.head ") {
            result.branch = value.trim().to_string();
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
                    entries: status.entries,
                },
            )
            .await;
        }
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
    }
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

/// Whether the hunk's post-image covers `lnum`. Pure deletions anchor on the
/// line the sign sits on (`new_start`, clamped to 1).
fn hunk_covers(new_start: u32, new_count: u32, lnum: u32) -> bool {
    if new_count == 0 {
        lnum == new_start.max(1)
    } else {
        lnum >= new_start && lnum < new_start + new_count
    }
}

/// Rewrite a hunk header so the hunk applies standalone. In a multi-hunk diff
/// each range is only absolute for its own side; `git apply` derives insertion
/// points from the *target* side, so rebase the other range onto it. Forward
/// application targets the index (old side), reverse the working tree (new
/// side).
fn lone_hunk_header(
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    revert: bool,
) -> String {
    if revert {
        let old_start = if new_count == 0 {
            new_start + 1
        } else if old_count == 0 {
            new_start.saturating_sub(1)
        } else {
            new_start
        };
        format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@")
    } else {
        let new_start = if old_count == 0 {
            old_start + 1
        } else if new_count == 0 {
            old_start.saturating_sub(1)
        } else {
            old_start
        };
        format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@")
    }
}

/// Build a minimal patch (file header plus the single hunk covering `lnum`)
/// from `git diff -U0` output.
fn extract_hunk_patch(stdout: &str, lnum: u32, revert: bool) -> Option<String> {
    let mut header: Vec<&str> = Vec::new();
    let mut hunk: Vec<String> = Vec::new();
    let mut in_header = true;
    let mut keep = false;
    for line in stdout.lines() {
        if line.starts_with("@@ ") {
            in_header = false;
            if keep {
                break;
            }
            hunk.clear();
            if let Some((old_start, old_count, new_start, new_count)) = parse_hunk_header(line) {
                keep = hunk_covers(new_start, new_count, lnum);
                hunk.push(lone_hunk_header(
                    old_start, old_count, new_start, new_count, revert,
                ));
            }
        } else if in_header {
            header.push(line);
        } else {
            hunk.push(line.to_string());
        }
    }
    if !keep || header.is_empty() {
        return None;
    }
    let mut patch = header.join("\n");
    patch.push('\n');
    patch.push_str(&hunk.join("\n"));
    patch.push('\n');
    Some(patch)
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
async fn buffer_hunk_diff(id: u64, path: &str, content: &str) -> Result<String, String> {
    if content.len() > MAX_CONTENT_BYTES {
        return Err("buffer too large for a live diff".to_string());
    }
    let dir = file_dir(path);
    let name = file_name(path)?;
    let prefix = run_git(&dir, &["rev-parse", "--show-prefix"]).await?;
    let spec = format!(":{}{}", prefix.trim_end_matches('\n'), name);
    let index_text = run_git(&dir, &["show", &spec]).await?;

    let stem = std::env::temp_dir().join(format!("simplegit-{}-{id}", std::process::id()));
    let index_file = stem.with_extension("index");
    let buffer_file = stem.with_extension("buffer");
    let write = async {
        tokio::fs::write(&index_file, &index_text)
            .await
            .map_err(|error| format!("failed to write temp file: {error}"))?;
        tokio::fs::write(&buffer_file, content)
            .await
            .map_err(|error| format!("failed to write temp file: {error}"))
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
        let args: Vec<&str> = match op.as_str() {
            "add" => vec!["add", "--", file.as_str()],
            "reset" => vec!["reset", "-q", "--", file.as_str()],
            _ => return Err(format!("unsupported file operation: {op}")),
        };
        run_git(&dir, &args).await
    }
    .await;
    match result {
        Ok(_) => send_event(&tx, &Event::FileOp { id, op, path }).await,
        Err(message) => send_event(&tx, &Event::Error { id, message }).await,
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
        let patch = extract_hunk_patch(&diff, lnum, revert)
            .ok_or_else(|| "no hunk under cursor".to_string())?;
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
        Request::Log { id, path, .. } => (*id, Some(path)),
        Request::GraphLog { id, path, .. } => (*id, Some(path)),
        Request::Show { id, path, .. } => (*id, Some(path)),
        Request::Cat { id, path, .. } => (*id, Some(path)),
        Request::Status { id, path } => (*id, Some(path)),
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
    let mut requests = JoinSet::new();

    while let Some(line) = read_request_line(&mut input).await? {
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
                    },
                )
                .await;
            }
            Request::Blame { id, path } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_blame(id, path, tx, permit));
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
            Request::Hunks { id, path, content } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_hunks(id, path, content, tx, permit));
            }
            Request::Stage { id, path, lnum } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_hunk_op(id, path, lnum, false, tx, permit));
            }
            Request::Undo { id, path, lnum } => {
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_hunk_op(id, path, lnum, true, tx, permit));
            }
            Request::FileOp { id, path, op, file } => {
                if let Err(message) = validate_request_path(&file) {
                    send_event(&out_tx, &Event::Error { id, message }).await;
                    continue;
                }
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_file_op(id, path, op, file, tx, permit));
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
                let tx = out_tx.clone();
                let permit = git_limiter.clone().acquire_owned().await.unwrap();
                requests.spawn(handle_commit(id, path, message, amend, tx, permit));
            }
        }
    }

    while let Some(result) = requests.join_next().await {
        report_request_completion(result, &out_tx).await;
    }
    drop(out_tx);
    let _ = writer.await;
    Ok(())
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
        None => match run(io::stdin(), io::stdout()).await {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("simplegit-daemon: {error}");
                std::process::ExitCode::FAILURE
            }
        },
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
        assert_eq!(result.commits[sha_a].time, 1_700_000_000);
        assert_eq!(result.commits[sha_b].summary, "second commit");
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
        assert_eq!(lone_hunk_header(3, 1, 5, 1, false), "@@ -3,1 +3,1 @@");
        assert_eq!(lone_hunk_header(10, 0, 11, 2, false), "@@ -10,0 +11,2 @@");
        assert_eq!(lone_hunk_header(20, 3, 22, 0, false), "@@ -20,3 +19,0 @@");
        assert_eq!(lone_hunk_header(0, 0, 1, 2, false), "@@ -0,0 +1,2 @@");
        // Reverse (undo): the new range is absolute for the working tree.
        assert_eq!(lone_hunk_header(3, 1, 5, 1, true), "@@ -5,1 +5,1 @@");
        assert_eq!(lone_hunk_header(10, 0, 11, 2, true), "@@ -10,0 +11,2 @@");
        assert_eq!(lone_hunk_header(20, 3, 22, 0, true), "@@ -23,3 +22,0 @@");
        // The staged '+seven' regression: insertion extracted after a net -1
        // earlier hunk must land after old line 6, not before it.
        assert_eq!(lone_hunk_header(6, 0, 6, 1, false), "@@ -6,0 +7,1 @@");
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

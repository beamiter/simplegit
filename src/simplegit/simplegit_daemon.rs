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
// A valid path may expand sixfold when JSON escapes ASCII control bytes. Keep
// enough headroom for the request envelope and a maximum-width u64 request ID.
const MAX_REQUEST_LINE_BYTES: usize = MAX_REQUEST_PATH_BYTES * 6 + 1024;
const MAX_OUTPUT_LINES: usize = 200_000;
const PROTOCOL_VERSION: u32 = 1;
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

async fn run_git(dir: &Path, args: &[&str]) -> Result<String, String> {
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
        Request::Show { id, path, .. } => (*id, Some(path)),
        Request::Cat { id, path, .. } => (*id, Some(path)),
        Request::Status { id, path } => (*id, Some(path)),
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
        if let Some(path) = path {
            if let Err(message) = validate_request_path(path) {
                send_event(&out_tx, &Event::Error { id, message }).await;
                continue;
            }
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
        }
    }

    while let Some(result) = requests.join_next().await {
        report_request_completion(result, &out_tx).await;
    }
    drop(out_tx);
    let _ = writer.await;
    Ok(())
}

#[tokio::main]
async fn main() -> io::Result<()> {
    run(io::stdin(), io::stdout()).await
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
        assert!(response.contains("\"protocol\":1"));
    }
}

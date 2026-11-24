//! Read-only selected-line preview for ordinary saved local tracked files.
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const FILE_LIMIT: usize = 256 * 1024;
const INDEX_LIMIT: usize = 8 * 1024 * 1024;
const DIFF_LIMIT: usize = 1024 * 1024;
const MAX_ROWS: usize = 16_384;
// Linux x86-64 only; other targets do not expose this CLI operation.
const O_PATH: i32 = 0o10000000;
const O_NOFOLLOW: i32 = 0o400000;
static SCRATCH_ID: AtomicU64 = AtomicU64::new(0);

type PreviewResult<T> = Result<T, String>;
type FileIdentity = (u64, u64, u32);

fn fail(message: &str) -> String {
    message.to_owned()
}

fn read_limited(reader: impl Read, max: usize) -> PreviewResult<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take((max + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > max {
        return Err(fail("selected-line preview exceeds its byte budget"));
    }
    Ok(bytes)
}

fn git_command(cwd: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new("git");
    cmd.current_dir(cwd)
        .args(args)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("GIT_") {
            cmd.env_remove(key);
        }
    }
    // Set known safeguards after deleting inherited Git environment.
    cmd.env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("GIT_NO_REPLACE_OBJECTS", "1")
        .env("GIT_ALLOW_PROTOCOL", "")
        // A repository can configure an executable fsmonitor for otherwise
        // read-only commands. The preview must not invoke it or other hooks.
        .env("GIT_CONFIG_COUNT", "2")
        .env("GIT_CONFIG_KEY_0", "core.fsmonitor")
        .env("GIT_CONFIG_VALUE_0", "false")
        .env("GIT_CONFIG_KEY_1", "core.hooksPath")
        .env("GIT_CONFIG_VALUE_1", "/dev/null");
    cmd
}

fn git(
    cwd: &Path,
    args: &[&str],
    input: Option<&Path>,
    limit: usize,
    ok: &[i32],
) -> PreviewResult<Vec<u8>> {
    let mut cmd = git_command(cwd, args);
    cmd.stdin(match input {
        Some(path) => Stdio::from(File::open(path).map_err(|e| e.to_string())?),
        None => Stdio::null(),
    });
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    let bytes = read_limited(
        child.stdout.take().ok_or_else(|| fail("no Git stdout"))?,
        limit,
    );
    if bytes.is_err() {
        let _ = child.kill();
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let bytes = bytes?;
    if !status.code().is_some_and(|code| ok.contains(&code)) {
        return Err(format!("read-only Git command failed: {}", args[0]));
    }
    Ok(bytes)
}

struct Scratch(PathBuf);
impl Scratch {
    fn new() -> PreviewResult<Self> {
        for _ in 0..32 {
            let path = Path::new("/tmp").join(format!(
                "simplegit-line-preview-{}-{}",
                std::process::id(),
                SCRATCH_ID.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => return Ok(Self(path)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e.to_string()),
            }
        }
        Err(fail("could not allocate private preview scratch"))
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

// Walk pinned directory descriptors; never open a path by following a changed
// component or a symlink. O_PATH lets us reject devices/FIFOs before reading.
fn read_regular(path: &Path, limit: usize) -> PreviewResult<(FileIdentity, Vec<u8>)> {
    let open_path = |path: &Path| {
        OpenOptions::new()
            .read(true)
            .custom_flags(O_PATH | O_NOFOLLOW)
            .open(path)
            .map_err(|e| e.to_string())
    };
    let fd_path = |file: &File| PathBuf::from(format!("/proc/self/fd/{}", file.as_raw_fd()));
    let mut file = open_path(Path::new("/"))?;
    for piece in path.components() {
        match piece {
            Component::RootDir => {}
            Component::Normal(name) => {
                if !file.metadata().map_err(|e| e.to_string())?.is_dir() {
                    return Err(fail(
                        "selected-line preview rejects symlinks or non-directory parents",
                    ));
                }
                file = open_path(&fd_path(&file).join(name))?;
            }
            _ => {
                return Err(fail(
                    "selected-line preview requires a normal absolute path",
                ));
            }
        }
    }
    let stat = file.metadata().map_err(|e| e.to_string())?;
    if !stat.is_file() || stat.len() > limit as u64 {
        return Err(fail(
            "selected-line preview requires a small regular non-symlink file",
        ));
    }
    let read = File::open(fd_path(&file)).map_err(|e| e.to_string())?;
    Ok((
        (stat.dev(), stat.ino(), stat.mode()),
        read_limited(read, limit)?,
    ))
}

fn saved_file(path: &Path) -> PreviewResult<(FileIdentity, Vec<u8>)> {
    read_regular(path, FILE_LIMIT)
}

// A proof for a bounded, ordinary single index. Linked worktrees, separate
// Git dirs and split-index repositories may still preview, but have no
// single-file snapshot identity suitable for a later conditional operation.
fn index_snapshot(root: &Path) -> Option<(FileIdentity, Vec<u8>)> {
    let dot_git = root.join(".git");
    if !dot_git.symlink_metadata().ok()?.is_dir()
        || !git(
            root,
            &["rev-parse", "--path-format=absolute", "--shared-index-path"],
            None,
            4096,
            &[0],
        )
        .ok()?
        .is_empty()
    {
        return None;
    }
    let path = dot_git.join("index");
    let actual = git(
        root,
        &["rev-parse", "--path-format=absolute", "--git-path", "index"],
        None,
        4096,
        &[0],
    )
    .ok()?;
    if actual.strip_suffix(b"\n")? != path.as_os_str().as_encoded_bytes() {
        return None;
    }
    read_regular(&path, INDEX_LIMIT).ok()
}

fn diff(scratch: &Path, right: &str) -> PreviewResult<Vec<u8>> {
    git(
        scratch,
        &[
            "--no-pager",
            "diff",
            "--no-index",
            "--no-color",
            "--no-ext-diff",
            "--no-textconv",
            "--no-indent-heuristic",
            "--inter-hunk-context=0",
            "--diff-algorithm=myers",
            "--unified=0",
            "--",
            "base",
            right,
        ],
        None,
        DIFF_LIMIT,
        &[0, 1],
    )
}

fn line_range(field: &str) -> Option<(usize, usize)> {
    let (first, count) = field.split_once(',').unwrap_or((field, "1"));
    let first: usize = first.parse().ok()?;
    let count: usize = count.parse().ok()?;
    Some((
        if count == 0 {
            first
        } else {
            first.checked_sub(1)?
        },
        count,
    ))
}

fn header(line: &[u8]) -> Option<(usize, usize, usize, usize)> {
    let s = std::str::from_utf8(line).ok()?.strip_prefix("@@ -")?;
    let (old, rem) = s.split_once(" +")?;
    let (new, _) = rem.split_once(" @@")?;
    let (i, a) = line_range(old)?;
    let (j, b) = line_range(new)?;
    Some((i, a, j, b))
}

fn rows(data: &[u8]) -> PreviewResult<Vec<&[u8]>> {
    let text =
        std::str::from_utf8(data).map_err(|_| fail("selected-line preview supports UTF-8 only"))?;
    if text.chars().any(|ch| (ch.is_control() && !matches!(ch, '\r' | '\n' | '\t'))
        || matches!(ch, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
        || data.windows(2).any(|pair| pair[0] == b'\r' && pair[1] != b'\n')
    {
        return Err(fail("selected-line preview rejects terminal controls and embedded CR"));
    }
    let rows = data
        .split_inclusive(|&byte| byte == b'\n')
        .collect::<Vec<_>>();
    if rows.len() > MAX_ROWS {
        return Err(fail("selected-line preview exceeds its line budget"));
    }
    Ok(rows)
}

fn consume_row<'a>(
    parts: &mut impl Iterator<Item = &'a [u8]>,
    sign: u8,
    row: &[u8],
) -> PreviewResult<()> {
    let next = parts.next().ok_or_else(|| fail("missing diff row"))?;
    let payload = next
        .strip_prefix(&[sign])
        .ok_or_else(|| fail("unexpected diff row kind"))?;
    if row.ends_with(b"\n") {
        if payload != row {
            return Err(fail("Git diff row failed byte verification"));
        }
    } else if payload.strip_suffix(b"\n") != Some(row)
        || parts.next() != Some(b"\\ No newline at end of file\n")
    {
        return Err(fail("Git diff lost exact end-of-file identity"));
    }
    Ok(())
}

fn select(
    base: &[u8],
    saved: &[u8],
    full_diff: &[u8],
    first: usize,
    last: usize,
) -> PreviewResult<Vec<u8>> {
    let old_rows = rows(base)?;
    let new_rows = rows(saved)?;
    if first == 0 || first > last || last > new_rows.len() {
        return Err(fail("selected range does not belong to the saved file"));
    }
    let selected = first - 1..last;
    let mut source = full_diff
        .split_inclusive(|&byte| byte == b'\n')
        .skip_while(|line| !line.starts_with(b"@@ "));
    let mut output = Vec::new();
    let (mut old, mut new) = (0, 0);
    while let Some(line) = source.next() {
        let (i, a, j, b) = header(line).ok_or_else(|| fail("invalid Git hunk header"))?;
        if i < old
            || j < new
            || a > old_rows.len().saturating_sub(i)
            || b > new_rows.len().saturating_sub(j)
            || i > old_rows.len()
            || j > new_rows.len()
            || (a == 0 && b == 0)
            || old_rows[old..i] != new_rows[new..j]
        {
            return Err(fail("Git hunk does not match the captured files"));
        }
        output.extend_from_slice(&old_rows[old..i]);
        for row in &old_rows[i..i + a] {
            consume_row(&mut source, b'-', row)?;
        }
        for row in &new_rows[j..j + b] {
            consume_row(&mut source, b'+', row)?;
        }
        let lo = j.max(selected.start);
        let hi = (j + b).min(selected.end);
        if lo < hi {
            if a != 0 && (lo != j || hi != j + b) {
                return Err(fail(
                    "partial replacement is ambiguous; select all replacement rows",
                ));
            }
            output.extend_from_slice(&new_rows[lo..hi]);
        } else {
            // Deletions have no postimage rows and are not implicitly selected.
            output.extend_from_slice(&old_rows[i..i + a]);
        }
        old = i + a;
        new = j + b;
    }
    if old_rows[old..] != new_rows[new..] {
        return Err(fail("Git diff omitted a changed byte range"));
    }
    output.extend_from_slice(&old_rows[old..]);
    if output
        .iter()
        .take(output.len().saturating_sub(1))
        .any(|row| !row.ends_with(b"\n"))
    {
        return Err(fail("selection would implicitly add a missing line ending"));
    }
    let bytes = output.concat();
    if bytes == base {
        return Err(fail("selection has no stageable lines"));
    }
    if bytes.len() > FILE_LIMIT {
        return Err(fail("selected content exceeds byte budget"));
    }
    Ok(bytes)
}

fn blob_id(raw: &[u8]) -> PreviewResult<&str> {
    let s = std::str::from_utf8(raw)
        .map_err(|e| e.to_string())?
        .trim_end_matches('\n');
    if !matches!(s.len(), 40 | 64) || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(fail("Git returned invalid blob identity"));
    }
    Ok(s)
}

fn index_entry(root: &Path, file: &str) -> PreviewResult<(String, String)> {
    let record = git(
        root,
        &[
            "--literal-pathspecs",
            "ls-files",
            "-v",
            "--stage",
            "-z",
            "--",
            file,
        ],
        None,
        4096,
        &[0],
    )?;
    let record = std::str::from_utf8(&record).map_err(|e| e.to_string())?;
    let (info, path) = record
        .split_once('\t')
        .ok_or_else(|| fail("file not tracked"))?;
    let parts: Vec<_> = info.split(' ').collect();
    if path.strip_suffix('\0') != Some(file)
        || parts.len() != 4
        || parts[0] != "H"
        || !matches!(parts[1], "100644" | "100755")
        || parts[3] != "0"
    {
        return Err(fail(
            "preview requires one ordinary tracked stage-zero index entry",
        ));
    }
    let debug = git(
        root,
        &["--literal-pathspecs", "ls-files", "--debug", "--", file],
        None,
        4096,
        &[0],
    )?;
    if !debug.ends_with(b"\tflags: 0\n") {
        return Err(fail("preview does not support special index entry flags"));
    }
    Ok((
        parts[1].to_owned(),
        blob_id(parts[2].as_bytes())?.to_owned(),
    ))
}

fn plain_attributes(root: &Path, file: &str) -> PreviewResult<()> {
    let output = git(
        root,
        &[
            "check-attr",
            "-z",
            "text",
            "eol",
            "filter",
            "diff",
            "working-tree-encoding",
            "ident",
            "--",
            file,
        ],
        None,
        4096,
        &[0],
    )?;
    let expected = [
        "text",
        "eol",
        "filter",
        "diff",
        "working-tree-encoding",
        "ident",
    ]
    .iter()
    .map(|key| format!("{file}\0{key}\0unspecified\0"))
    .collect::<String>();
    let autocrlf = git(
        root,
        &["config", "--bool", "--get", "core.autocrlf"],
        None,
        64,
        &[0, 1],
    )?;
    if output != expected.as_bytes() || !matches!(autocrlf.as_slice(), b"" | b"false\n") {
        return Err(fail(
            "preview does not support filtered or normalized line coordinates",
        ));
    }
    Ok(())
}

struct Preview {
    root: PathBuf,
    path: PathBuf,
    file: String,
    entry: (String, String),
    saved: (FileIdentity, Vec<u8>),
    index: Option<(FileIdentity, Vec<u8>)>,
    index_id: String,
    saved_id: String,
    proposed_id: String,
    scratch: Scratch,
    output: Vec<u8>,
}

fn preview(
    path: &Path,
    first: usize,
    last: usize,
    expected: Option<&[u8]>,
) -> PreviewResult<Preview> {
    // Restrict V1 to files whose names are represented literally in unified
    // diff headers, not display-path quoting or virtual/foreign workspaces.
    let path = std::path::absolute(path).map_err(|e| e.to_string())?;
    let (identity, saved) = saved_file(&path)?;
    if expected.is_some_and(|bytes| bytes != saved) {
        return Err(fail(
            "saved bytes no longer match the Vim buffer; reload before previewing",
        ));
    }
    rows(&saved)?;
    let parent = path.parent().ok_or_else(|| fail("missing file parent"))?;
    let root = git(parent, &["rev-parse", "--show-toplevel"], None, 4096, &[0])?;
    let root_name = std::str::from_utf8(&root)
        .map_err(|e| e.to_string())?
        .strip_suffix('\n')
        .ok_or_else(|| fail("Git omitted its worktree path terminator"))?;
    if root_name.chars().any(|ch| ch.is_control()
        || matches!(ch, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'))
    {
        return Err(fail("Git returned a non-displayable worktree path"));
    }
    let root = Path::new(root_name);
    let file = path
        .strip_prefix(root)
        .ok()
        .and_then(Path::to_str)
        .filter(|file| {
            !file.is_empty()
                && file
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_./-".contains(&b))
        })
        .ok_or_else(|| fail("preview requires a simple repository-relative file name"))?;
    let whole_index = index_snapshot(root);
    let entry = index_entry(root, file)?;
    plain_attributes(root, file)?;
    let base = git(
        root,
        &["cat-file", "blob", &entry.1],
        None,
        FILE_LIMIT,
        &[0],
    )?;
    rows(&base)?;
    let executable = identity.2 & 0o100 != 0;
    if executable != (entry.0 == "100755") {
        return Err(fail(
            "selected-line preview does not include file mode changes",
        ));
    }

    let scratch = Scratch::new()?;
    fs::write(scratch.0.join("base"), &base).map_err(|e| e.to_string())?;
    fs::write(scratch.0.join("saved"), &saved).map_err(|e| e.to_string())?;
    let diff_bytes = diff(&scratch.0, "saved")?;
    let proposed = select(&base, &saved, &diff_bytes, first, last)?;
    fs::write(scratch.0.join("proposed"), &proposed).map_err(|e| e.to_string())?;
    let oid = |name: &str| -> PreviewResult<String> {
        let p = scratch.0.join(name);
        let output = git(
            root,
            &["hash-object", "--no-filters", "--stdin"],
            Some(&p),
            128,
            &[0],
        )?;
        Ok(blob_id(&output)?.to_owned())
    };
    let saved_id = oid("saved")?;
    let proposed_id = oid("proposed")?;
    let index_id = if let Some((_, bytes)) = &whole_index {
        fs::write(scratch.0.join("index-preimage"), bytes).map_err(|e| e.to_string())?;
        oid("index-preimage")?
    } else {
        "unavailable".to_owned()
    };
    let rendered = diff(&scratch.0, "proposed")?;
    let body = rendered
        .split_inclusive(|&byte| byte == b'\n')
        .skip_while(|line| !line.starts_with(b"@@ "))
        .flatten()
        .copied()
        .collect::<Vec<_>>();
    if body.is_empty() {
        return Err(fail("Git did not render a textual selected-line patch"));
    }
    // Last checks are not an apply lock. They disallow a known stale preview;
    // this CLI offers no commit operation and does not write index or objects.
    plain_attributes(root, file)?;
    let saved_snapshot = (identity, saved);
    if index_entry(root, file)? != entry || saved_file(&path)? != saved_snapshot {
        return Err(fail(
            "index entry or saved file changed while building preview",
        ));
    }
    if whole_index.is_some() && index_snapshot(root) != whole_index {
        return Err(fail("Git index changed while building preview"));
    }
    let mut out = format!(
        "Selected-line preview only (no changes)\nworktree {root_name}\npath {file}\nmode {}\nbase {}\nsaved {saved_id}\nproposed {proposed_id}\nindex-snapshot {index_id}\n--- a/{file}\n+++ b/{file}\n",
        entry.0, entry.1
    ).into_bytes();
    out.extend(body);
    Ok(Preview {
        root: root.to_path_buf(),
        file: file.to_owned(),
        path,
        entry,
        saved: saved_snapshot,
        index: whole_index,
        index_id,
        saved_id,
        proposed_id,
        scratch,
        output: out,
    })
}

// Git itself owns and cleans up the original index.lock. Before a proposed
// record has been sent, closing stdin asks it to exit without any mutation.
struct NativeIndexWriter(Child);

impl Drop for NativeIndexWriter {
    fn drop(&mut self) {
        drop(self.0.stdin.take());
        let _ = self.0.wait();
    }
}

impl NativeIndexWriter {
    fn start(root: &Path) -> PreviewResult<Self> {
        git_command(root, &["update-index", "--index-info"])
            .stdout(Stdio::null())
            .stdin(Stdio::piped())
            .spawn()
            .map(Self)
            .map_err(|e| e.to_string())
    }

    fn owns_lock(&mut self, root: &Path) -> PreviewResult<()> {
        let lock = root.join(".git/index.lock");
        let fds = PathBuf::from(format!("/proc/{}/fd", self.0.id()));
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if self.0.try_wait().map_err(|e| e.to_string())?.is_some() {
                return Err(fail("Git could not acquire the index lock"));
            }
            if let Ok(stat) = lock.symlink_metadata()
                && stat.is_file()
                && fs::read_dir(&fds).is_ok_and(|entries| {
                    entries.flatten().any(|fd| {
                        fs::metadata(fd.path())
                            .is_ok_and(|m| m.dev() == stat.dev() && m.ino() == stat.ino())
                    })
                })
            {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Err(fail("could not verify that Git owns the index lock"))
    }

    fn commit(&mut self, mode: &str, oid: &str, file: &str) -> PreviewResult<()> {
        let mut input = self
            .0
            .stdin
            .take()
            .ok_or_else(|| fail("Git stdin closed"))?;
        // Only a tracked, plain ASCII file path and Git-validated mode/OID
        // reach this record. A partial record without its newline is invalid.
        writeln!(input, "{mode} {oid}\t{file}").map_err(|e| e.to_string())?;
        drop(input);
        if !self.0.wait().map_err(|e| e.to_string())?.success() {
            return Err(fail(
                "Git did not confirm the staged update; check the index before retrying",
            ));
        }
        Ok(())
    }
}

fn ordinary_index_config(root: &Path) -> PreviewResult<()> {
    for key in ["core.splitIndex", "index.sparse"] {
        let value = git(root, &["config", "--bool", "--get", key], None, 64, &[0, 1])?;
        if !matches!(value.as_slice(), b"" | b"false\n") {
            return Err(fail(
                "confirmed staging requires an ordinary single Git index",
            ));
        }
    }
    Ok(())
}

pub fn run_confirmed_stage(args: &[String], mut output: impl Write) -> PreviewResult<()> {
    let [index, saved, proposed, first, last, separator, path] = args else {
        return Err(fail(
            "usage: --stage-selected-lines-confirmed INDEX SAVED PROPOSED FIRST LAST -- FILE",
        ));
    };
    if separator != "--" {
        return Err(fail("expected -- before the saved path"));
    }
    for oid in [index, saved, proposed] {
        blob_id(oid.as_bytes())?;
    }
    let first = first
        .parse()
        .map_err(|_| fail("invalid first selected line"))?;
    let last = last
        .parse()
        .map_err(|_| fail("invalid last selected line"))?;
    let plan = preview(Path::new(path), first, last, None)?;
    if plan.index.is_none()
        || &plan.index_id != index
        || &plan.saved_id != saved
        || &plan.proposed_id != proposed
    {
        return Err(fail(
            "reviewed index or content changed; preview again before staging",
        ));
    }
    ordinary_index_config(&plan.root)?;
    let mut writer = NativeIndexWriter::start(&plan.root)?;
    writer.owns_lock(&plan.root)?;
    ordinary_index_config(&plan.root)?;
    if index_snapshot(&plan.root) != plan.index
        || saved_file(&plan.path)? != plan.saved
        || index_entry(&plan.root, &plan.file)? != plan.entry
    {
        return Err(fail(
            "index or saved file changed before confirmation; preview again",
        ));
    }
    plain_attributes(&plan.root, &plan.file)?;
    let blob = git(
        &plan.root,
        &["hash-object", "--no-filters", "-w", "--stdin"],
        Some(&plan.scratch.0.join("proposed")),
        128,
        &[0],
    )?;
    let oid = blob_id(&blob)?;
    if oid != proposed
        || index_snapshot(&plan.root) != plan.index
        || saved_file(&plan.path)? != plan.saved
    {
        return Err(fail(
            "index or saved file changed before staging; preview again",
        ));
    }
    writer.commit(&plan.entry.0, oid, &plan.file)?;
    writeln!(output, "Selected lines staged: {}", plan.file).map_err(|e| {
        format!("selected lines were staged, but the receipt could not be written: {e}")
    })
}

pub fn run_cli(
    args: &[String],
    from_buffer: bool,
    mut input: impl Read,
    mut output: impl Write,
) -> PreviewResult<()> {
    let (args, expected_len) = if from_buffer {
        let Some((len, args)) = args.split_first() else {
            return Err(fail("missing selected buffer byte count"));
        };
        let len = len
            .parse::<usize>()
            .ok()
            .filter(|&len| len <= FILE_LIMIT)
            .ok_or_else(|| fail("selected buffer exceeds its byte budget"))?;
        (args, Some(len))
    } else {
        (args, None)
    };
    let [first, last, separator, path] = args else {
        return Err(fail("usage: --preview-selected-lines FIRST LAST -- FILE"));
    };
    if separator != "--" {
        return Err(fail("expected -- before the saved path"));
    }
    let first = first
        .parse()
        .map_err(|_| fail("invalid first selected line"))?;
    let last = last
        .parse()
        .map_err(|_| fail("invalid last selected line"))?;
    // Bounded exact frame, not an EOF protocol. Vim can queue a nonblocking
    // channel write and leave stdin open until the job exits.
    let expected = if let Some(len) = expected_len {
        let mut bytes = vec![0; len];
        input.read_exact(&mut bytes).map_err(|e| e.to_string())?;
        Some(bytes)
    } else {
        None
    };
    output
        .write_all(&preview(Path::new(path), first, last, expected.as_deref())?.output)
        .map_err(|e| e.to_string())
}

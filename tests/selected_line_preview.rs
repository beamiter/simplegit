#![cfg(all(target_os = "linux", target_arch = "x86_64"))]

use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

static ID: AtomicUsize = AtomicUsize::new(0);
const BIN: &str = env!("CARGO_BIN_EXE_simplegit-daemon");

struct Repo(PathBuf);

impl Repo {
    fn new(indexed: &[u8], saved: &[u8]) -> Self {
        let p = std::env::temp_dir().join(format!(
            "simplegit-selected-test-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        let repo = Self(p);
        repo.git(&["init", "-q"]);
        repo.git(&["config", "core.autocrlf", "false"]);
        repo.git(&["config", "core.fileMode", "true"]);
        fs::write(repo.path(), indexed).unwrap();
        repo.git(&["add", "--", "chosen.txt"]);
        fs::write(repo.path(), saved).unwrap();
        repo
    }

    fn path(&self) -> PathBuf {
        self.0.join("chosen.txt")
    }

    fn git(&self, args: &[&str]) -> Vec<u8> {
        let output = Command::new("git")
            .current_dir(&self.0)
            .args(args)
            .output()
            .unwrap();
        assert!(output.status.success(), "{args:?}: {output:?}");
        output.stdout
    }

    fn run(&self, first: &str, last: &str, path: &Path) -> Output {
        // A fake inherited external diff would fail the preview if consulted.
        Command::new(BIN)
            .env("GIT_EXTERNAL_DIFF", "/does-not-exist")
            .arg("--preview-selected-lines")
            .args([first, last, "--"])
            .arg(path)
            .output()
            .unwrap()
    }

    fn counts(&self) -> Vec<u8> {
        self.git(&["count-objects", "-v"])
    }

    fn success(&self, first: &str, last: &str) -> Vec<u8> {
        let index = fs::read(self.0.join(".git/index")).unwrap();
        let before = fs::read(self.path()).unwrap();
        let objects = self.counts();
        let result = self.run(first, last, &self.path());
        assert!(result.status.success(), "{result:?}");
        assert_eq!(fs::read(self.0.join(".git/index")).unwrap(), index);
        assert_eq!(fs::read(self.path()).unwrap(), before);
        assert_eq!(self.counts(), objects, "preview wrote Git objects");
        result.stdout
    }

    fn rejects(&self, first: &str, last: &str, path: &Path, reason: &str) {
        let index = fs::read(self.0.join(".git/index")).unwrap();
        let result = self.run(first, last, path);
        assert!(
            !result.status.success() && result.stdout.is_empty(),
            "{result:?}"
        );
        assert!(
            String::from_utf8_lossy(&result.stderr).contains(reason),
            "{result:?}"
        );
        assert_eq!(fs::read(self.0.join(".git/index")).unwrap(), index);
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn picks_a_single_crlf_insert_row_and_preserves_no_final_lf() {
    let r = Repo::new(
        b"one\r\nkept\r\nold-tail",
        b"one\r\nSELECT\r\nNO-DEBUG\r\nkept\r\nnew-tail",
    );
    let output = r.success("2", "2");
    assert!(
        output
            .windows(b"+SELECT\r\n".len())
            .any(|p| p == b"+SELECT\r\n")
    );
    let text = String::from_utf8(output).unwrap();
    assert!(!text.contains("NO-DEBUG") && !text.contains("new-tail"));
    for field in [
        "path chosen.txt",
        "mode 100644",
        "base ",
        "saved ",
        "proposed ",
    ] {
        assert!(text.contains(field));
    }
    let eof = String::from_utf8(r.success("5", "5")).unwrap();
    assert!(eof.contains("+new-tail\n\\ No newline at end of file\n"));
    assert!(eof.contains("-old-tail\n\\ No newline at end of file\n"));
    assert!(!eof.contains("+SELECT"));
}

#[test]
fn rejects_partial_replacement_or_deletion_and_accepts_complete_replacement() {
    let r = Repo::new(
        b"a\nold1\nold2\nkeep\ndelete\nz\n",
        b"a\nnew1\nnew2\nnew3\nkeep\nz\n",
    );
    r.rejects("2", "2", &r.path(), "ambiguous");
    r.rejects("5", "6", &r.path(), "no stageable lines");
    let text = String::from_utf8(r.success("2", "4")).unwrap();
    assert!(text.contains("-old1\n-old2\n+new1\n+new2\n+new3\n"));
    assert!(!text.contains("-delete"));
}

#[test]
fn rejects_escape_controls_links_and_nontracked_or_filtered_paths() {
    let r = Repo::new(b"base\n", b"changed\n");
    let untracked = r.0.join("untracked.txt");
    fs::write(&untracked, b"local\n").unwrap();
    r.rejects("1", "1", &untracked, "not tracked");
    let link = r.0.join("link.txt");
    symlink(r.path(), &link).unwrap();
    r.rejects("1", "1", &link, "non-symlink");
    fs::write(r.0.join(".gitattributes"), b"chosen.txt text eol=lf\n").unwrap();
    r.rejects("1", "1", &r.path(), "normalized");
    fs::remove_file(r.0.join(".gitattributes")).unwrap();
    fs::write(r.path(), b"untrusted\x1b[31m\n").unwrap();
    r.rejects("1", "1", &r.path(), "terminal controls");
}

#[test]
fn rejects_intent_to_add_without_losing_index_flags() {
    let r = Repo::new(b"old\n", b"new\n");
    let placeholder = r.0.join("placeholder.txt");
    fs::write(&placeholder, b"added?\n").unwrap();
    r.git(&["add", "-N", "--", "placeholder.txt"]);
    r.rejects("1", "1", &placeholder, "special index entry flags");
}

#[test]
fn a_real_external_index_write_invalidates_the_preview() {
    let r = Repo::new(b"old\n", b"new\n");
    let path = std::env::var_os("PATH").unwrap();
    let git = std::env::split_paths(&path)
        .map(|d| d.join("git"))
        .find(|p| p.is_file())
        .unwrap();
    let bin = r.0.join("race-tools");
    fs::create_dir(&bin).unwrap();
    let shim = bin.join("git");
    let reached = r.0.join("race-reached");
    fs::write(
        &shim,
        r#"#!/bin/sh
if [ "$1" = hash-object ] && [ ! -e "$RACE_REACHED" ]; then
    "$REAL_GIT" -C "$RACE_REPO" add -- chosen.txt || exit 100
    : > "$RACE_REACHED"
fi
exec "$REAL_GIT" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).unwrap();
    let mut dirs = vec![bin];
    dirs.extend(std::env::split_paths(&path));
    let old_index = fs::read(r.0.join(".git/index")).unwrap();
    let output = Command::new(BIN)
        .env("PATH", std::env::join_paths(dirs).unwrap())
        .env("RACE_REACHED", &reached)
        .env("RACE_REPO", &r.0)
        .env("REAL_GIT", git)
        .args(["--preview-selected-lines", "1", "1", "--"])
        .arg(r.path())
        .output()
        .unwrap();
    assert!(reached.exists(), "external writer did not run");
    assert!(
        output.stdout.is_empty() && !output.status.success(),
        "{output:?}"
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("index entry or saved file changed"));
    assert_ne!(fs::read(r.0.join(".git/index")).unwrap(), old_index);
    assert_eq!(r.git(&["show", ":chosen.txt"]), b"new\n");
}

#[test]
fn preview_never_runs_repository_fsmonitor() {
    let r = Repo::new(b"old\n", b"new\n");
    let monitor = r.0.join("monitor");
    let marker = r.0.join("executed");
    fs::write(
        &monitor,
        format!("#!/bin/sh\n: > '{}'\nprintf '1000\n'\n", marker.display()),
    )
    .unwrap();
    fs::set_permissions(&monitor, fs::Permissions::from_mode(0o700)).unwrap();
    r.git(&["config", "core.fsmonitor", monitor.to_str().unwrap()]);
    r.success("1", "1");
    assert!(
        !marker.exists(),
        "read-only preview invoked repository executable"
    );
}

#[test]
fn confirmed_buffer_requires_exact_saved_bytes_and_a_bounded_complete_frame() {
    use std::io::Write;
    use std::process::Stdio;

    let r = Repo::new(b"old\r\ntail", b"old\r\nnew\r\ntail");
    let run = |declared: usize, input: &[u8]| {
        let mut child = Command::new(BIN)
            .arg("--preview-selected-buffer-lines")
            .arg(declared.to_string())
            .args(["2", "2", "--"])
            .arg(r.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        child.wait_with_output().unwrap()
    };
    let saved = b"old\r\nnew\r\ntail";
    let success = run(saved.len(), saved);
    assert!(success.status.success(), "{success:?}");
    assert!(success.stdout.ends_with(b"+new\r\n"));
    let wrong = b"old\r\nBAD\r\ntail";
    let mismatch = run(wrong.len(), wrong);
    assert!(mismatch.stdout.is_empty() && !mismatch.status.success());
    assert!(String::from_utf8_lossy(&mismatch.stderr).contains("saved bytes no longer match"));
    let short = run(saved.len(), &saved[..saved.len() - 1]);
    assert!(short.stdout.is_empty() && !short.status.success());
    let large = run(256 * 1024 + 1, b"");
    assert!(large.stdout.is_empty() && !large.status.success());
    assert!(String::from_utf8_lossy(&large.stderr).contains("byte budget"));
}

#[test]
fn reports_a_whole_index_snapshot_only_for_an_ordinary_index() {
    let r = Repo::new(b"old\n", b"new\n");
    let expected = r.git(&["hash-object", "--no-filters", ".git/index"]);
    let expected = std::str::from_utf8(&expected).unwrap().trim_end();
    let text = String::from_utf8(r.success("1", "1")).unwrap();
    assert!(text.contains(&format!("\nindex-snapshot {expected}\n")));
    r.git(&["update-index", "--split-index"]);
    let split = r.run("1", "1", &r.path());
    if split.status.success() {
        let text = String::from_utf8(split.stdout).unwrap();
        assert!(text.contains("\nindex-snapshot unavailable\n"));
    } else {
        // Git versions can expose split entries as special index flags,
        // which already make a preview ineligible.
        assert!(split.stdout.is_empty());
        assert!(String::from_utf8_lossy(&split.stderr).contains("special index entry flags"));
    }
}

#[test]
fn unrelated_git_writer_retires_the_whole_index_preview() {
    let r = Repo::new(b"old\n", b"new\n");
    fs::write(r.0.join("other.txt"), b"before\n").unwrap();
    r.git(&["add", "other.txt"]);
    fs::write(r.0.join("other.txt"), b"independent\n").unwrap();
    let bin = r.0.join("shim");
    fs::create_dir(&bin).unwrap();
    let reached = r.0.join("writer-ran");
    let shim = bin.join("git");
    let path = std::env::var_os("PATH").unwrap();
    let real_git = std::env::split_paths(&path)
        .map(|p| p.join("git"))
        .find(|p| p.is_file())
        .unwrap();
    fs::write(
        &shim,
        r#"#!/bin/sh
if [ "$1" = --no-pager ] && [ ! -e "$RACE_REACHED" ]; then
    "$REAL_GIT" -C "$RACE_REPO" add -- other.txt || exit 92
    : >"$RACE_REACHED"
fi
exec "$REAL_GIT" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).unwrap();
    let mut dirs = vec![bin];
    dirs.extend(std::env::split_paths(&path));
    let output = Command::new(BIN)
        .env("PATH", std::env::join_paths(dirs).unwrap())
        .env("RACE_REACHED", &reached)
        .env("RACE_REPO", &r.0)
        .env("REAL_GIT", real_git)
        .args(["--preview-selected-lines", "1", "1", "--"])
        .arg(r.path())
        .output()
        .unwrap();
    assert!(reached.exists(), "external writer did not run");
    assert!(
        !output.status.success() && output.stdout.is_empty(),
        "{output:?}"
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("Git index changed"));
    assert_eq!(r.git(&["show", ":chosen.txt"]), b"old\n");
    assert_eq!(r.git(&["show", ":other.txt"]), b"independent\n");
    assert_eq!(fs::read(r.path()).unwrap(), b"new\n");
    assert!(!r.0.join(".git/index.lock").exists());
}

fn confirmation(r: &Repo, first: &str, last: &str) -> Vec<String> {
    let preview = String::from_utf8(r.success(first, last)).unwrap();
    ["index-snapshot ", "saved ", "proposed "]
        .iter()
        .map(|key| {
            preview
                .lines()
                .find_map(|row| row.strip_prefix(key))
                .unwrap()
                .to_owned()
        })
        .chain([first.to_owned(), last.to_owned(), "--".to_owned()])
        .chain([r.path().to_str().unwrap().to_owned()])
        .collect()
}

fn confirm(args: &[String]) -> Output {
    Command::new(BIN)
        .arg("--stage-selected-lines-confirmed")
        .args(args)
        .output()
        .unwrap()
}

#[test]
fn confirmed_stage_updates_only_the_reviewed_crlf_row() {
    let saved = b"one\r\nSELECT\r\nNO-DEBUG\r\ntail";
    let r = Repo::new(b"one\r\ntail", saved);
    fs::write(r.0.join("other.txt"), b"unrelated staged file\n").unwrap();
    r.git(&["add", "other.txt"]);
    let args = confirmation(&r, "2", "2");
    let before = fs::read(r.0.join(".git/index")).unwrap();
    let output = confirm(&args);
    assert!(output.status.success(), "{output:?}");
    assert_ne!(fs::read(r.0.join(".git/index")).unwrap(), before);
    assert_eq!(r.git(&["show", ":chosen.txt"]), b"one\r\nSELECT\r\ntail");
    assert_eq!(r.git(&["show", ":other.txt"]), b"unrelated staged file\n");
    assert_eq!(fs::read(r.path()).unwrap(), saved);
    assert!(!r.0.join(".git/index.lock").exists());
    let after = fs::read(r.0.join(".git/index")).unwrap();
    assert!(
        !confirm(&args).status.success(),
        "a confirmation was reused"
    );
    assert_eq!(fs::read(r.0.join(".git/index")).unwrap(), after);
}

#[test]
fn confirmation_rejects_changed_tokens_saved_bytes_and_busy_lock() {
    let r = Repo::new(b"old\n", b"new\n");
    let args = confirmation(&r, "1", "1");
    let original = fs::read(r.0.join(".git/index")).unwrap();
    let objects = r.counts();
    for slot in 0..3 {
        let mut wrong = args.clone();
        wrong[slot] = "0".repeat(wrong[slot].len());
        let output = confirm(&wrong);
        assert!(!output.status.success() && output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("preview again"));
    }
    fs::write(r.path(), b"not reviewed\n").unwrap();
    assert!(!confirm(&args).status.success());
    fs::write(r.path(), b"new\n").unwrap();
    let lock = r.0.join(".git/index.lock");
    fs::write(&lock, b"unrelated writer").unwrap();
    let output = confirm(&args);
    assert!(!output.status.success() && output.stdout.is_empty());
    assert_eq!(fs::read(&lock).unwrap(), b"unrelated writer");
    assert_eq!(fs::read(r.0.join(".git/index")).unwrap(), original);
    assert_eq!(r.counts(), objects, "rejected confirmation wrote objects");
    fs::remove_file(lock).unwrap();
}

#[test]
fn writer_before_native_lock_rejects_confirmation_without_touching_either_entry() {
    let r = Repo::new(b"old\n", b"new\n");
    fs::write(r.0.join("other.txt"), b"before\n").unwrap();
    r.git(&["add", "other.txt"]);
    let args = confirmation(&r, "1", "1");
    fs::write(r.0.join("other.txt"), b"independent\n").unwrap();
    let bin = r.0.join("shim");
    fs::create_dir(&bin).unwrap();
    let reached = r.0.join("writer-ran");
    let shim = bin.join("git");
    let path = std::env::var_os("PATH").unwrap();
    let real_git = std::env::split_paths(&path)
        .map(|p| p.join("git"))
        .find(|p| p.is_file())
        .unwrap();
    fs::write(
        &shim,
        r#"#!/bin/sh
if [ "$1" = update-index ] && [ ! -e "$RACE_REACHED" ]; then
    "$REAL_GIT" -C "$RACE_REPO" add -- other.txt || exit 92
    : >"$RACE_REACHED"
fi
exec "$REAL_GIT" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&shim, fs::Permissions::from_mode(0o700)).unwrap();
    let mut dirs = vec![bin];
    dirs.extend(std::env::split_paths(&path));
    let output = Command::new(BIN)
        .env("PATH", std::env::join_paths(dirs).unwrap())
        .env("RACE_REACHED", &reached)
        .env("RACE_REPO", &r.0)
        .env("REAL_GIT", real_git)
        .arg("--stage-selected-lines-confirmed")
        .args(&args)
        .output()
        .unwrap();
    assert!(reached.exists(), "intervening writer did not run");
    assert!(
        !output.status.success() && output.stdout.is_empty(),
        "{output:?}"
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("changed before confirmation"));
    assert_eq!(r.git(&["show", ":chosen.txt"]), b"old\n");
    assert_eq!(r.git(&["show", ":other.txt"]), b"independent\n");
    assert_eq!(fs::read(r.path()).unwrap(), b"new\n");
    assert!(!r.0.join(".git/index.lock").exists());
}

#[test]
fn confirmation_refuses_configuration_that_would_convert_the_index() {
    let r = Repo::new(b"old\n", b"new\n");
    let args = confirmation(&r, "1", "1");
    let before = fs::read(r.0.join(".git/index")).unwrap();
    r.git(&["config", "core.splitIndex", "true"]);
    let output = confirm(&args);
    assert!(!output.status.success() && output.stdout.is_empty());
    // Different Git versions can detect the now-unsupported layout during
    // review revalidation or at the explicit ordinary-index gate.
    assert!(!output.stderr.is_empty());
    assert_eq!(fs::read(r.0.join(".git/index")).unwrap(), before);
    assert!(!r.0.join(".git/index.lock").exists());
}

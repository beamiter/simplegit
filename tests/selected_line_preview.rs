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

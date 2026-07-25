#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$root_dir"

cargo build --release --locked
mkdir -p lib
tmp_binary="$(mktemp "$root_dir/lib/.simplegit-daemon.XXXXXX")"
trap 'rm -f "$tmp_binary"' EXIT
install -m 0755 target/release/simplegit-daemon "$tmp_binary"
mv -f "$tmp_binary" lib/simplegit-daemon
trap - EXIT

if command -v vim >/dev/null 2>&1; then
  vim -Nu NONE -n -i NONE -es -c 'helptags doc' -c 'qa!'
else
  echo "Warning: Vim was not found on PATH; run :helptags $root_dir/doc manually." >&2
fi

echo "Installed simplegit-daemon to $root_dir/lib/simplegit-daemon"

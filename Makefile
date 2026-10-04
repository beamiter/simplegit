.PHONY: check fmt clippy test vim-test vim-integration vim-commit vim-file-ops vim-statusline vim-blame vim-views vim-hunks vim-queue vim-watch vim-remote vim-reload vim-core defcompile core-verify doc-tags

check: core-verify doc-tags fmt clippy test vim-test vim-integration vim-commit vim-file-ops vim-statusline vim-blame vim-views vim-hunks vim-queue vim-watch vim-remote vim-reload defcompile vim-core

doc-tags:
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' 0; \
	cp doc/*.txt "$$tmp/"; \
	DOC_TAGS_TMP="$$tmp" vim -Nu NONE -n -i NONE -es \
	  -c 'execute "helptags " .. fnameescape($$DOC_TAGS_TMP)' -c 'qa!' </dev/null; \
	status=0; \
	foreign=$$(awk -F'\t' '$$1 !~ /^(simplegit|g:simplegit|b:simplegit|:SimpleGit|SimpleGitUpdate|<Plug>\(simplegit)/ { print $$1 }' "$$tmp/tags"); \
	if [ -n "$$foreign" ]; then \
	  echo "doc: *word* in prose defined a global help tag: $$foreign" >&2; status=1; fi; \
	[ $$status -eq 0 ] && echo "doc: help tags are valid and plugin-scoped"

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

vim-test:
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# Drives the real daemon; skips cleanly when lib/simplegit-daemon is absent.
vim-integration:
	# This suite verifies a linewise Visual text object.  Ex mode cannot enter
	# Visual mode, even through :normal, so run normal Vim while keeping its
	# screen rendering out of successful build logs.  On failure the captured
	# terminal/error stream is replayed, and the final cquit is a sentinel for a
	# script that aborted before reaching its own qall!/cquit!.
	@log=$$(mktemp); status=0; \
	vim -Nu NONE -n -i NONE -S tests/vim_integration.vim -c 'cquit!' >$$log 2>&1 || status=$$?; \
	if [ $$status -ne 0 ]; then cat $$log >&2; fi; \
	rm -f $$log; exit $$status

# Drives real `git commit` inside throwaway repositories.
vim-commit:
	vim -Nu NONE -n -i NONE -es -S tests/vim_commit.vim

# Protocol capability fallback plus tab/window/status generation races.
vim-file-ops:
	vim -Nu NONE -n -i NONE -es -S tests/vim_file_ops.vim

# The public statusline API: b:simplegit_status_dict, User SimpleGitUpdate and
# the accessors.  Statusline expressions run on every redraw, so this also
# pins that none of them dispatches a request.
vim-statusline:
	vim -Nu NONE -n -i NONE -es -S tests/vim_statusline.vim

# Per-line blame: the `git blame -L` request, its capability fallback to the
# whole-file blame, the per-line cache and g:simplegit_blame_format.
vim-blame:
	vim -Nu NONE -n -i NONE -es -S tests/vim_blame.vim

# Asynchronously opened views (show / history / log / diff): tab-scoped scratch
# reuse, and replies that land after the user moved on.
vim-views:
	vim -Nu NONE -n -i NONE -es -S tests/vim_views.vim

# Hunk navigation and preview requested while a refresh is already in flight.
vim-hunks:
	vim -Nu NONE -n -i NONE -es -S tests/vim_hunks.vim

vim-queue:
	vim -Nu NONE -n -i NONE -es -S tests/vim_queue.vim

# Repository watch: per-repository registration, the unsolicited repo_change
# event, and that a change in one repository leaves the others alone.
vim-watch:
	vim -Nu NONE -n -i NONE -es -S tests/vim_watch.vim

# SimpleRemote workspaces: a remote:// buffer routed to the git of the
# workspace host (exec prefix plus cwd on every request), the refusals when
# that is not possible, and the projected 'always' mode.  SimpleRemote itself
# is not on the runtimepath; its API is stubbed and its events fired by hand.
vim-remote:
	vim -Nu NONE -n -i NONE -es -S tests/vim_remote.vim

vim-reload:
	vim -Nu NONE -n -i NONE -es -S tests/vim_reload.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simplegit/core.vim.
#
# These lines are vendored too.  They are the tail of this Makefile — nothing
# above the banner belongs to the bundle — and `.simplecore.manifest` records
# them as a `footer` fragment.  Until it did, they were the one bundle member
# copied by hand and hashed by nothing, so core-verify could not see them
# drift; nine plugins carried an installer in the same position.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
#
# Whole files are plain `sha256sum -c` records.  A fragment — a run of lines
# inside a file the plugin itself owns, like this footer — is recorded as
# `footer <lines> <sha256>  <path>` and checked against the tail of <path>.
core-verify:
	@awk ' \
	  /^[[:space:]]*(\#|$$)/ { next } \
	  $$1 == "version" && NF == 2 && $$2 ~ /^[1-9][0-9]*$$/ { versions++; next } \
	  length($$1) == 64 && $$1 !~ /[^0-9a-f]/ && NF == 2 { files++; next } \
	  $$1 == "footer" && NF == 4 && $$2 ~ /^[1-9][0-9]*$$/ \
	    && length($$3) == 64 && $$3 !~ /[^0-9a-f]/ { footers++; next } \
	  { bad = 1 } \
	  END { if (bad || versions != 1 || files == 0 || footers != 1) { \
	    print ".simplecore.manifest: invalid or incomplete bundle records" > "/dev/stderr"; exit 1 } } \
	' .simplecore.manifest
	@records=$$(grep -cE '^[0-9a-f]{64}' .simplecore.manifest); \
	checked=$$(grep -cE '^[0-9a-f]{64}  ' .simplecore.manifest); \
	test "$$records" = "$$checked" || { \
	  echo ".simplecore.manifest: $$((records - checked)) hash record(s) not checked" >&2; \
	  echo "  a record whose separator is not exactly two spaces is dropped by the" >&2; \
	  echo "  reader below and would verify green while its file went unchecked." >&2; \
	  exit 1; }
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@awk '$$1 == "footer" { print $$2, $$3, $$4 }' .simplecore.manifest \
	| while read -r lines sum path; do \
		test -f "$$path" && fragment=$$(tail -n "$$lines" "$$path") || exit 1; \
		test "$$(printf '%s\n' "$$fragment" | sha256sum | cut -d' ' -f1)" = "$$sum" \
		|| { echo "$$path: FAILED (simplecore footer)" >&2; exit 1; }; \
	done
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# core-verify proves this repository is internally consistent: every vendored
# copy still matches the manifest written beside it.  It cannot prove freshness.
# A plugin that misses a re-vendor keeps verifying its own stale copy for ever,
# and stays green doing it, because the bundle is deliberately not required to
# be present for the build to work.  This target is the other half, for when it
# is present; `check` cannot depend on it without making the bundle a build
# dependency, which is the coupling the vendoring exists to avoid.
SIMPLECORE_DIR ?= ../.simplecore
core-fresh:
	@if [ -x "$(SIMPLECORE_DIR)/vendor.sh" ]; then \
	  SIMPLECORE_SUITE="$(patsubst %/,%,$(dir $(CURDIR)))" \
	    "$(SIMPLECORE_DIR)/vendor.sh" --check "$(notdir $(CURDIR))"; \
	else \
	  echo "simplecore: $(SIMPLECORE_DIR) is not checked out; freshness unverified"; \
	fi

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts, and both outcomes of the protocol
# handshake — the reply that lands, and the deadline that expires and fails the
# start.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim

.PHONY: core-verify core-fresh vim-core defcompile

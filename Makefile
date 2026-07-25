.PHONY: check fmt clippy test vim-test vim-integration

check: fmt clippy test vim-test vim-integration

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
	vim -Nu NONE -n -i NONE -es -S tests/vim_integration.vim

.PHONY: all test build clean check format lint check-duplication install-tools

all: build test

build:
	cargo build --all

test:
	cargo test --all
	cargo run -p xs-tools --bin xsc -- test

clean:
	cargo clean
	rm -rf .xs-codebase

check: format lint test check-duplication

format:
	cargo fmt --all

lint:
	cargo clippy --all-targets --all-features -- -D warnings

check-duplication:
	@command -v similarity-rs >/dev/null 2>&1 || (echo "Installing similarity-rs..." && cargo install similarity-rs)
	@echo "Checking for code duplication..."
	@similarity-rs . || true

install-tools:
	cargo install similarity-rs
	rustup component add rustfmt clippy

# Development helpers
watch:
	cargo watch -x test

bench:
	cargo bench

doc:
	cargo doc --no-deps --open

# XS specific commands
run-shell:
	cargo run -p xs-tools --bin xs-shell

run-tests:
	cargo run -p xs-tools --bin xsc -- test

test-xs:
	cargo run -p xs-tools --bin xsc -- test xs/

# Component Model commands
wit-gen:
	@if [ -z "$(FILE)" ]; then echo "Usage: make wit-gen FILE=examples/module.xs"; exit 1; fi
	cargo run -p xs-tools --bin xsc -- component generate-wit $(FILE)

# Release build
release:
	cargo build --release --all

# CI simulation
ci: check test
	@echo "All CI checks passed!"
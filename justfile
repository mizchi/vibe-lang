# MoonBit Project Commands

# Default target (js for browser compatibility)
target := "js"
home := env_var_or_default("HOME", "/tmp")
prefix := env_var_or_default("XSH_PREFIX", home + "/.local")
bindir := prefix + "/bin"
cli_bin := "target/native/release/build/xsh_cli/xsh_cli.exe"

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Type check
check:
    moon check --deny-warn --target {{target}}

# Run tests (includes fixtures and examples)
test:
    moon test --target {{target}}
    moon run src/xsh_cli/main.mbt --target native -- test examples/*.xsh

# Run fixture tests only
test-fixtures:
    moon test -p xsh --filter "fixtures" --target {{target}}

# Update snapshot tests
test-update:
    moon test --update --target {{target}}

# Run CLI
run *args:
    moon run --target native src/xsh_cli -- {{args}}

# Install native CLI to $XSH_PREFIX/bin (default: ~/.local/bin)
install:
    moon build --target native --release src/xsh_cli
    mkdir -p {{bindir}}
    cp {{cli_bin}} {{bindir}}/xsh

# Benchmark wasm execution via wasmtime
bench-wasmtime:
    scripts/bench_wasmtime.sh

# Compare interpreter vs wasmtime
bench-compare:
    scripts/bench_compare.sh

# Compare wasm js-string vs wasm gc on string-heavy workload
bench-string-compare:
    scripts/bench_string_compare.sh

# String benchmarks (js-string vs wasm-gc)
bench-string-concat:
    scripts/bench_string_compare.sh bench/bench_string_concat.xsh

bench-string-substring:
    scripts/bench_string_compare.sh bench/bench_string_substring.xsh

bench-string-equals:
    scripts/bench_string_compare.sh bench/bench_string_equals.xsh

# Benchmark builder-based immutable snapshot
bench-builder:
    scripts/bench_builder.sh

# Measure per-command latency after startup
bench-cmd-latency:
    scripts/bench_cmd_latency.sh

# Measure parse/type/compile+run per command after startup
bench-cmd-compile:
    scripts/bench_cmd_compile.sh

# Run wasm-js-string backend via JS engine
run-wasm-js-string *args:
    node scripts/run_wasm_js_string.mjs {{args}}

# Generate type definition files
info:
    moon info

# Clean build artifacts
clean:
    moon clean

# E2E tests for Component Model and WIT
test-component-e2e:
    scripts/test_component_e2e.sh

# Tests for WASM codegen unsupported syntax
test-codegen-unsupported:
    scripts/test_codegen_unsupported.sh

# Golden tests for WAT output
test-golden-wat:
    scripts/test_golden_wat.sh

# Update golden WAT snapshots
test-golden-wat-update:
    scripts/test_golden_wat.sh --update

# Test interpreter vs WASM output consistency
test-interpreter-wasm:
    scripts/test_interpreter_wasm_match.sh

# Run wasmtime in x86_64 Linux container (for stack-switching support)
wasmtime-x64 *args:
    container run --platform linux/amd64 -v $(pwd):/work -v /tmp:/tmp rust:bookworm bash -c '\
      curl -sSf https://wasmtime.dev/install.sh | bash >/dev/null 2>&1 && \
      export PATH="$HOME/.wasmtime/bin:$PATH" && \
      cd /work && \
      wasmtime {{args}}'

# Run wasmtime with stack-switching enabled (x86_64 only)
wasmtime-stack-switching file *args:
    container run --platform linux/amd64 -v $(pwd):/work -v /tmp:/tmp rust:bookworm bash -c '\
      curl -sSf https://wasmtime.dev/install.sh | bash >/dev/null 2>&1 && \
      export PATH="$HOME/.wasmtime/bin:$PATH" && \
      wasmtime run -W stack-switching=y -W exceptions=y -W function-references=y {{args}} /work/{{file}}'

# Build async host runtime (Rust/wasmtime)
build-async-host:
    cargo build --release --manifest-path examples/async_host/Cargo.toml

# Run sleep demo with async host runtime
sleep-demo: build-async-host
    moon run --target native src/xsh_cli -- compile --wasm examples/wasm/sleep_demo.xsh -o /tmp/sleep_demo.wasm
    examples/async_host/target/release/xsh-async-host /tmp/sleep_demo.wasm

# Run WASM file with async host runtime (supports sleep)
run-wasm-async file: build-async-host
    examples/async_host/target/release/xsh-async-host {{file}}

# Pre-release check
release-check: fmt info check test

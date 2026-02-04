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

# Run tests
test:
    moon test --target {{target}}
    moon run src/xsh_cli/main.mbt --target native -- test examples/*.xsh

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

# Run fixture tests only
fixtures:
    moon test --filter "fixtures" --target {{target}}

# Generate type definition files
info:
    moon info

# Clean build artifacts
clean:
    moon clean

# Pre-release check
release-check: fmt info check test

# MoonBit Project Commands

# Default target (js for browser compatibility)
target := "js"
home := env_var_or_default("HOME", "/tmp")
prefix := env_var_or_default("XSH_PREFIX", home + "/.local")
bindir := prefix + "/bin"
cli_bin := "target/native/release/build/cmd/xsh/xsh.exe"
# 0: prefer system wasmtime, 1: force deps/wasmtime build
xsh_use_wasmtime_submodule := env_var_or_default("XSH_USE_WASMTIME_SUBMODULE", "0")
# space-separated flags, each token is passed as `-W <token>`
xsh_wasmtime_wasm_flags := env_var_or_default("XSH_WASMTIME_WASM_FLAGS", "")
# space-separated flags, each token is passed as `-S <token>`
xsh_wasmtime_wasi_flags := env_var_or_default("XSH_WASMTIME_WASI_FLAGS", "")

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Type check
check:
    moon check --deny-warn --target {{target}}

# Run tests (includes fixtures, examples, and core std library)
test:
    moon test --target {{target}}
    moon run src/cmd/xsh/main.mbt --target native -- test --unstable-async examples xsh/std

# Build wasm artifact used by Deno integration tests
build-integration-deno-wasm:
    moon build --target wasm-gc src/lib

# Run Deno integration tests (artifact-only, no command spawn)
test-integration-deno: build-integration-deno-wasm
    deno test --allow-read tests/integration-deno

# Run JS-backed xsh ide command (artifact-only wasm service)
ide-js *args: build-integration-deno-wasm
    deno run --allow-read js/xsh/cli.js ide {{args}}

# Run fixture tests only
test-fixtures:
    moon test -p tests --filter "fixtures" --target {{target}}

# Run typecheck diagnostic fixture tests
test-typecheck-fixtures:
    moon test -p checker -f typecheck_fixture_test.mbt --target {{target}}

# Update typecheck diagnostic fixtures
test-typecheck-fixtures-update:
    scripts/typecheck_fixtures.sh --update

# Run warning diagnostic fixture tests
test-warning-fixtures:
    moon test -p checker -f warning_fixture_test.mbt --target {{target}}

# Update warning diagnostic fixtures
test-warning-fixtures-update:
    scripts/warning_fixtures.sh --update

# Update snapshot tests
test-update:
    moon test --update --target {{target}}

# Run CLI
run *args:
    moon run --target native src/cmd/xsh -- {{args}}

# Build wasm line REPL package (wasi preview2 imports)
build-repl-wasi-wasm:
    moon build --target wasm src/cmd/xsh_wasi

# Build wasm compiler CLI package (filesystem adapter via src/io)
build-compiler-wasi-wasm:
    moon build --target wasm src/cmd/xsh_compile_wasi

# Build wasm checker CLI package (JSON diagnostics)
build-checker-wasi-wasm:
    moon build --target wasm src/cmd/xsh_check_wasi

# Run wasm compiler CLI through moon wasm runner
run-compiler-wasi-wasm *args:
    moon run --target wasm src/cmd/xsh_compile_wasi -- {{args}}

# Run wasm checker CLI through moon wasm runner
run-checker-wasi-wasm *args:
    moon run --target wasm src/cmd/xsh_check_wasi -- {{args}}

# Run wasm compiler CLI (wasm-gc preferred backend)
run-compiler-wasi-wasm-gc *args:
    moon run --target wasm src/cmd/xsh_compile_wasi -- --wasm {{args}}

# Run wasm compiler CLI (core wasm MVP backend)
run-compiler-wasi-wasm-mvp *args:
    moon run --target wasm src/cmd/xsh_compile_wasi -- --wasm-mvp {{args}}

# Build + run a stdio component (`run()` by default)
component-run file out="" invoke="run()":
    if [ -n "{{out}}" ]; then \
      XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" \
      XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" \
      XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} \
      scripts/run_component_stdio.sh {{file}} {{out}} '{{invoke}}'; \
    else \
      XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" \
      XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" \
      XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} \
      scripts/run_component_stdio.sh {{file}} '' '{{invoke}}'; \
    fi

# Run sample stream-TUI demo with canned stdin
demo-tui-stream:
    printf 'hello\nworld\n' | XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/run_component_stdio.sh examples/wasm/tui_stream_demo.xsh '' 'run()' | awk 'NR==1{prev=$0;next}{print prev;prev=$0} END{if (prev !~ /^-?[0-9]+$/) print prev}'

# Build + run a stdio component with moonix (`run()` by default)
component-run-moonix file out="" invoke="run()":
    if [ -n "{{out}}" ]; then \
      scripts/run_component_moonix.sh {{file}} {{out}} '{{invoke}}'; \
    else \
      scripts/run_component_moonix.sh {{file}} '' '{{invoke}}'; \
    fi

# Try to bootstrap moonix binary from local moonix source checkout
bootstrap-moonix src="":
    if [ -n "{{src}}" ]; then \
      scripts/bootstrap_moonix_bin.sh {{src}}; \
    else \
      scripts/bootstrap_moonix_bin.sh; \
    fi

# Install native CLI to $XSH_PREFIX/bin (default: ~/.local/bin)
install:
    moon build --target native --release src/cmd/xsh
    mkdir -p {{bindir}}
    cp {{cli_bin}} {{bindir}}/xsh

# Benchmark wasm execution via wasmtime
bench-wasmtime:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_wasmtime.sh

# Compare interpreter vs wasmtime
bench-compare:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_compare.sh

# Compare wasm js-string vs wasm gc on string-heavy workload
bench-string-compare:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_string_compare.sh

# String benchmarks (js-string vs wasm-gc)
bench-string-concat:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_concat.xsh

bench-string-substring:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_substring.xsh

bench-string-equals:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_equals.xsh

# Base64 benchmark (js-string vs wasm-gc)
bench-base64:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_base64_encode.xsh

# Audit bench/*.xsh backend compatibility
bench-audit-backends:
    scripts/bench_audit_backends.sh

# Benchmark builder-based immutable snapshot
bench-builder:
    scripts/bench_builder.sh

# Measure per-command latency after startup
bench-cmd-latency:
    scripts/bench_cmd_latency.sh

# Measure parse/type/compile+run per command after startup
bench-cmd-compile:
    scripts/bench_cmd_compile.sh

# Benchmark symbol index + LSIF backend
bench-symbol-index:
    moon bench -p benches -f symbol_index_bench.mbt

# Benchmark advanced graph index PoC (search + remote delta apply)
bench-advanced-graph:
    moon bench -p benches -f advanced_graph_bench.mbt

# Benchmark typechecker and ripple type-cache behavior
bench-typechecker:
    moon bench -p benches -f checker_bench.mbt

# Benchmark bundle size for examples/ + use-case importers (bench/bundle_size/)
# Default importer mode is runtime-first (`--wasm`/`--wasm-js-string`).
# Set `XSH_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1` to add no-dce diagnostics.
# Set `XSH_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1` to include xsh/std module surfaces.
bench-bundle-size:
    scripts/bench_bundle_size.sh

# Update bundle-size golden budgets
bench-bundle-size-update:
    scripts/bench_bundle_size.sh --update

# Regenerate advanced graph flatbuffers schema bindings
gen-advanced-graph-fb:
    moon run src/cmd/fbgen/main.mbt --target js

# Run wasm-js-string backend via JS engine
run-wasm-js-string *args:
    node scripts/run_wasm_js_string.mjs {{args}}

# Generate builtin contract markdown table
gen-builtin-contract-table:
    node scripts/gen_builtin_contract_table.mjs

# Generate type definition files
info:
    moon info

# Clean build artifacts
clean:
    moon clean

# E2E tests for Component Model and WIT
test-component-e2e:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/test_component_e2e.sh

# Build a Component Model artifact using wkg + wasm-tools
component-wkg file out="":
    if [ -n "{{out}}" ]; then \
      scripts/component_wkg_stdio.sh {{file}} {{out}}; \
    else \
      scripts/component_wkg_stdio.sh {{file}}; \
    fi

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
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/test_interpreter_wasm_match.sh

# Show resolved wasmtime binary for current env selection
show-wasmtime-bin:
    XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} scripts/wasmtime_bin.sh

# Show resolved wasmtime runtime flag env values used by scripts/wasmtime_run.sh
show-wasmtime-flags:
    echo "XSH_WASMTIME_WASM_FLAGS={{xsh_wasmtime_wasm_flags}}"
    echo "XSH_WASMTIME_WASI_FLAGS={{xsh_wasmtime_wasi_flags}}"

# Run minimal WASI Threads probe module (requires wasmtime + wasm-tools)
wasi-threads-probe:
    XSH_WASMTIME_WASM_FLAGS="{{xsh_wasmtime_wasm_flags}}" XSH_WASMTIME_WASI_FLAGS="{{xsh_wasmtime_wasi_flags}}" XSH_USE_WASMTIME_SUBMODULE={{xsh_use_wasmtime_submodule}} src/x/threads/run_probe.sh

# Initialize wasmtime submodule for experimental runtime flags
wasmtime-submodule-init:
    git submodule update --init deps/wasmtime

# Update wasmtime submodule to latest upstream main
wasmtime-submodule-update:
    git submodule update --remote deps/wasmtime

# Build submodule wasmtime CLI (`profile=release` or `profile=debug`)
build-wasmtime-submodule profile="release": wasmtime-submodule-init
    if [ "{{profile}}" = "release" ]; then \
      cargo build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli --release; \
    else \
      cargo build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli; \
    fi

# Run submodule wasmtime CLI (build first if needed)
wasmtime-submodule *args:
    if [ -x deps/wasmtime/target/release/wasmtime ]; then \
      deps/wasmtime/target/release/wasmtime {{args}}; \
    elif [ -x deps/wasmtime/target/debug/wasmtime ]; then \
      deps/wasmtime/target/debug/wasmtime {{args}}; \
    else \
      echo "submodule wasmtime is not built. run: just build-wasmtime-submodule" >&2; \
      exit 1; \
    fi

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
    moon run --target native src/cmd/xsh -- compile --wasm examples/wasm/sleep_demo.xsh -o /tmp/sleep_demo.wasm
    examples/async_host/target/release/xsh-async-host /tmp/sleep_demo.wasm

# Run WASM file with async host runtime (supports sleep)
run-wasm-async file: build-async-host
    examples/async_host/target/release/xsh-async-host {{file}}

# Pre-release check
release-check: fmt info check test

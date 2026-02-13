# MoonBit Project Commands

# Default target (js for browser compatibility)
target := "js"
home := env_var_or_default("HOME", "/tmp")
prefix := env_var_or_default("VIBE_PREFIX", home + "/.local")
bindir := prefix + "/bin"
cli_bin := "target/native/release/build/cmd/vibe/vibe.exe"
# 0: prefer system wasmtime, 1: force deps/wasmtime build
vibe_use_wasmtime_submodule := env_var_or_default("VIBE_USE_WASMTIME_SUBMODULE", "0")
# space-separated flags, each token is passed as `-W <token>`
vibe_wasmtime_wasm_flags := env_var_or_default("VIBE_WASMTIME_WASM_FLAGS", "")
# space-separated flags, each token is passed as `-S <token>`
vibe_wasmtime_wasi_flags := env_var_or_default("VIBE_WASMTIME_WASI_FLAGS", "")
# suppress noisy import-liveness warnings while keeping other warnings active
moon_warn_list := env_var_or_default("VIBE_MOON_WARN_LIST", "-29")

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Type check
check:
    moon check --deny-warn --warn-list '{{moon_warn_list}}' --target {{target}}

# Run tests (includes fixtures, examples, std, collection, and encoding libraries)
test:
    moon test --target {{target}} --warn-list '{{moon_warn_list}}'
    moon build --target native src/cmd/vibe --warn-list '{{moon_warn_list}}'
    _build/native/debug/build/cmd/vibe/vibe.exe test --unstable-async examples vibe/std vibe/collection vibe/encoding

# Build wasm artifact used by Deno integration tests
build-integration-deno-wasm:
    moon build --target wasm-gc --release src/lib

# Build distributable wasm service artifact (`wasm/vibe/vibe.wasm`)
build-wasm-vibe: build-integration-deno-wasm
    mkdir -p wasm/vibe
    cp _build/wasm-gc/release/build/lib/lib.wasm wasm/vibe/vibe.wasm

# Smoke test `wasm/vibe/vibe.wasm` with wasmtime invoke
test-wasm-vibe-wasmtime: build-wasm-vibe
    scripts/test_wasm_vibe_wasmtime.sh wasm/vibe/vibe.wasm

# Run Deno integration tests (artifact-only, no command spawn)
test-integration-deno: build-integration-deno-wasm
    deno test --allow-read tests/integration-deno

# Run MoonBit source coverage (summary + cobertura + html)
# env: VIBE_MOON_COVERAGE_TARGET, VIBE_MOON_COVERAGE_PACKAGE, VIBE_MOON_COVERAGE_MIN_LINE, VIBE_MOON_COVERAGE_DIR
coverage-moon:
    scripts/coverage_moon.sh

# Run WASM integration coverage via Deno (summary + lcov + html)
# env: VIBE_DENO_COVERAGE_FILTER, VIBE_DENO_COVERAGE_MIN_LINE, VIBE_DENO_COVERAGE_DIR
coverage-deno:
    scripts/coverage_deno.sh

# Run source-level WASM coverage (vibe span map + runtime counters)
# env: VIBE_WASM_SOURCE_COVERAGE_MODE, VIBE_WASM_SOURCE_COVERAGE_NO_DCE, VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS, VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP, VIBE_WASM_SOURCE_COVERAGE_DIR
coverage-wasm-source entry="examples/pattern_coverage.vibe":
    scripts/coverage_wasm_source.sh {{entry}}

# Run vibe/std coverage from *_test.vibe via wasm source coverage
# env: VIBE_WASM_STD_COVERAGE_MODES, VIBE_WASM_STD_COVERAGE_MODE, VIBE_WASM_STD_COVERAGE_NO_DCE, VIBE_WASM_STD_COVERAGE_STRICT, VIBE_WASM_STD_COVERAGE_ALLOW_TRAP, VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE, VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE, VIBE_WASM_STD_COVERAGE_FILTER, VIBE_WASM_STD_COVERAGE_EXCLUDE, VIBE_WASM_STD_COVERAGE_MATRIX, VIBE_WASM_STD_COVERAGE_DIR
coverage-wasm-std:
    scripts/coverage_wasm_std.sh

# Run full coverage pipeline (MoonBit + WASM integration)
coverage: coverage-moon coverage-deno

# Run JS-backed vibe ide command (artifact-only wasm service)
ide-js *args: build-integration-deno-wasm
    deno run --allow-read js/vibe/cli.js ide {{args}}

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
    moon run --target native src/cmd/vibe -- {{args}}

# Build wasm line REPL package (wasi preview2 imports)
build-repl-wasi-wasm:
    moon build --target wasm src/cmd/vibe_wasi

# Build wasm compiler CLI package (filesystem adapter via src/io)
build-compiler-wasi-wasm:
    moon build --target wasm src/cmd/vibe_compile_wasi

# Build wasm checker CLI package (JSON diagnostics)
build-checker-wasi-wasm:
    moon build --target wasm src/cmd/vibe_check_wasi

# Run wasm compiler CLI through moon wasm runner
run-compiler-wasi-wasm *args:
    moon run --target wasm src/cmd/vibe_compile_wasi -- {{args}}

# Run wasm checker CLI through moon wasm runner
run-checker-wasi-wasm *args:
    moon run --target wasm src/cmd/vibe_check_wasi -- {{args}}

# Run wasm compiler CLI (wasm-gc preferred backend)
run-compiler-wasi-wasm-gc *args:
    moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm {{args}}

# Run wasm compiler CLI (core wasm MVP backend)
run-compiler-wasi-wasm-mvp *args:
    moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm-mvp {{args}}

# Build + run a stdio component (`run()` by default)
component-run file out="" invoke="run()":
    if [ -n "{{out}}" ]; then \
      VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" \
      VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" \
      VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} \
      scripts/run_component_stdio.sh {{file}} {{out}} '{{invoke}}'; \
    else \
      VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" \
      VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" \
      VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} \
      scripts/run_component_stdio.sh {{file}} '' '{{invoke}}'; \
    fi

# Run sample stream-TUI demo with canned stdin
demo-tui-stream:
    printf 'hello\nworld\n' | VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/run_component_stdio.sh examples/wasm/tui_stream_demo.vibe '' 'run()' | awk 'NR==1{prev=$0;next}{print prev;prev=$0} END{if (prev !~ /^-?[0-9]+$/) print prev}'

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

# Install native CLI to $VIBE_PREFIX/bin (default: ~/.local/bin)
install:
    moon build --target native --release src/cmd/vibe
    mkdir -p {{bindir}}
    cp {{cli_bin}} {{bindir}}/vibe

# Benchmark wasm execution via wasmtime
bench-wasmtime:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_wasmtime.sh

# Compare interpreter vs wasmtime
bench-compare:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_compare.sh

# Run language bench and collect latency + wasm size KPI in one report
# env: VIBE_BENCH_KPI_N, VIBE_BENCH_KPI_WARMUP, VIBE_BENCH_KPI_BACKEND, VIBE_BENCH_KPI_MAX_PER_US, VIBE_BENCH_KPI_MAX_WASM_BYTES, VIBE_BENCH_KPI_MAX_SCORE, VIBE_BENCH_KPI_DIR, VIBE_BENCH_KPI_REPORT
bench-kpi *paths:
    scripts/bench_kpi.sh {{paths}}

# Compare wasm js-string vs wasm gc on string-heavy workload
bench-string-compare:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh

# String benchmarks (js-string vs wasm-gc)
bench-string-concat:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_concat.vibe

bench-string-substring:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_substring.vibe

bench-string-equals:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_string_equals.vibe

# Base64 benchmark (js-string vs wasm-gc)
bench-base64:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh bench/bench_base64_encode.vibe

# Audit bench/*.vibe backend compatibility
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

# Benchmark scratch workflow stages (eval/finalize/export_apply/full)
# env: VIBE_BENCH_SCENARIOS, VIBE_BENCH_CHAIN, VIBE_BENCH_WARMUP, VIBE_BENCH_RUNS
bench-scratch-workflow:
    scripts/bench_scratch_workflow.sh

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
# Set `VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1` to add no-dce diagnostics.
# Set `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1` to include vibe/std module surfaces.
bench-bundle-size:
    scripts/bench_bundle_size.sh

# Update bundle-size golden budgets
bench-bundle-size-update:
    scripts/bench_bundle_size.sh --update

# Update std-focused benchmark baselines (bundle-size + KPI snapshots)
bench-std-baseline-update:
    VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1 VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1 scripts/bench_bundle_size.sh --update
    VIBE_BENCH_KPI_BACKEND=wasm VIBE_BENCH_KPI_REPORT=bench/golden/kpi_wasm.tsv scripts/bench_kpi.sh
    VIBE_BENCH_KPI_BACKEND=interpreter VIBE_BENCH_KPI_REPORT=bench/golden/kpi_interpreter.tsv scripts/bench_kpi.sh

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
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/test_component_e2e.sh

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
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/test_interpreter_wasm_match.sh

# Show resolved wasmtime binary for current env selection
show-wasmtime-bin:
    VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/wasmtime_bin.sh

# Show resolved wasmtime runtime flag env values used by scripts/wasmtime_run.sh
show-wasmtime-flags:
    echo "VIBE_WASMTIME_WASM_FLAGS={{vibe_wasmtime_wasm_flags}}"
    echo "VIBE_WASMTIME_WASI_FLAGS={{vibe_wasmtime_wasi_flags}}"

# Run minimal WASI Threads probe module (requires wasmtime + wasm-tools)
wasi-threads-probe:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} src/x/threads/run_probe.sh

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
    moon run --target native src/cmd/vibe -- compile --wasm examples/wasm/sleep_demo.vibe -o /tmp/sleep_demo.wasm
    examples/async_host/target/release/vibe-async-host /tmp/sleep_demo.wasm

# Run WASM file with async host runtime (supports sleep)
run-wasm-async file: build-async-host
    examples/async_host/target/release/vibe-async-host {{file}}

# Pre-release check
release-check: fmt info check test

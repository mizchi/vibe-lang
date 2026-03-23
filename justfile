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
vibe_wasmtime_wasm_flags := env_var_or_default("VIBE_WASMTIME_WASM_FLAGS", "unknown-imports-default=y")
# space-separated flags, each token is passed as `-S <token>`
vibe_wasmtime_wasi_flags := env_var_or_default("VIBE_WASMTIME_WASI_FLAGS", "")
# suppress noisy import-liveness warnings while keeping other warnings active
moon_warn_list := env_var_or_default("VIBE_MOON_WARN_LIST", "-1-7-24-29")
vibe_test_ulimit_n := env_var_or_default("VIBE_TEST_ULIMIT_N", "8192")
vibe_test_jobs := env_var_or_default("VIBE_TEST_JOBS", "1")
selfhost_suite_branch_extra_entries := `node scripts/coverage_selfhost_suite_next_branches.mjs --preset branch --format env`

# Default task: check and test
default: check test

# Format code
fmt:
    moon fmt

# Type check
check:
    moon check --deny-warn --warn-list '{{moon_warn_list}}' --target {{target}}

# Verify index.lock files do not contain temporary probe/debug entries
check-lock-clean:
    scripts/check_lock_clean.sh

# Self-test lock contamination checker patterns
test-lock-clean:
    scripts/check_lock_clean_test.sh

# Verify selfhost bundle matches manifest/source inputs
check-selfhost-bundle-sync:
    bash scripts/check_selfhost_bundle_sync.sh

# Self-test selfhost bundle drift checker
test-selfhost-bundle-sync:
    bash scripts/check_selfhost_bundle_sync_test.sh

# Refresh selfhost bootstrap batch weight seed from cached timings
refresh-selfhost-batch-weights:
    bash scripts/refresh_selfhost_batch_weight_seed.sh

# Self-test selfhost batch weight seed refresh helper
test-selfhost-batch-weights:
    bash scripts/refresh_selfhost_batch_weight_seed_test.sh

# Self-test builtin rename migration helper
test-rename-builtins:
    bash scripts/rename_builtins_test.sh

# Self-test normalize batching helper
test-vibe-normalize:
    bash scripts/vibe_normalize_all_test.sh

# Run tests (excludes heavy wasm tests; use `just test-full` for everything)
test:
    scripts/check_lock_clean.sh
    scripts/check_lock_clean_test.sh
    moon test --target {{target}} --warn-list '{{moon_warn_list}}'
    moon test -p mizchi/vibe/lib --target wasm-gc --warn-list '{{moon_warn_list}}'
    moon test -p mizchi/vibe/cmd/vibe -f cli_e2e_wbtest.mbt --target native --warn-list '{{moon_warn_list}}'
    moon test -p mizchi/vibe/cmd/vibe_check_wasi --target wasm --warn-list '{{moon_warn_list}}'
    bash -c 'source scripts/ensure_native_cli.sh'
    bash scripts/test_parallel_cleanup_e2e.sh _build/native/debug/build/cmd/vibe/vibe.exe
    bash scripts/test_internal_parent_watchdog_e2e.sh _build/native/debug/build/cmd/vibe/vibe.exe
    ulimit -n {{vibe_test_ulimit_n}} && _build/native/debug/build/cmd/vibe/vibe.exe test --unstable-async --jobs {{vibe_test_jobs}} examples vibe/prelude vibe/path vibe/io vibe/fs vibe/time vibe/random vibe/process vibe/shell vibe/x/rlm vibe/socket/socket_test.vibe vibe/http/http_test.vibe vibe/http/high_level_test.vibe vibe/collection vibe/json vibe/sha1 vibe/x vibe/x/args vibe/x/jsonschema vibe/wasm/wasm_parser vibe/wasm/wat_parser vibe/wasm/component_parser vibe/wasm/wat_encoder

# Heavy wasm tests (wasm_opt ~4min, wasm_runtime ~1min) — run separately or in CI
test-wasm-heavy:
    bash -c 'source scripts/ensure_native_cli.sh'
    _build/native/debug/build/cmd/vibe/vibe.exe test vibe/wasm/wasm_opt vibe/wasm/wasm_runtime

# Run all tests including heavy wasm tests
test-full: test test-wasm-heavy

# Build wasm artifact used by Deno integration tests
build-integration-deno-wasm:
    moon build --target wasm-gc --release src/lib

# Build distributable wasm service artifact (`wasm/vibe/vibe.wasm`)
build-wasm-vibe: build-integration-deno-wasm
    mkdir -p wasm/vibe
    cp _build/wasm-gc/release/build/lib/lib.wasm wasm/vibe/vibe.wasm

# Build distributable selfhost compiler wasm (with wasm-opt)
build-selfhost-dist:
    bash scripts/build_selfhost_dist.sh

# Build distributable selfhost compiler wasm (without wasm-opt)
build-selfhost-dist-raw:
    VIBE_DIST_SKIP_OPT=1 bash scripts/build_selfhost_dist.sh

# Build distributable selfhost GC compiler wasm (with wasm-opt)
build-selfhost-dist-gc:
    VIBE_DIST_ENTRY_PATH={{justfile_directory()}}/vibe/compiler/selfhost_cli_gc_entry.vibe bash scripts/build_selfhost_dist.sh

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
# env: VIBE_WASM_SOURCE_COVERAGE_MODE, VIBE_WASM_SOURCE_COVERAGE_NO_DCE, VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS, VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP, VIBE_WASM_SOURCE_COVERAGE_INVOKE, VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE, VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE, VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE, VIBE_WASM_SOURCE_COVERAGE_DIR
coverage-wasm-source entry="examples/pattern_coverage.vibe":
    scripts/coverage_wasm_source.sh {{entry}}

# Run selfhost compiler index coverage with helper invoke
coverage-selfhost-index entry="vibe/compiler/index.vibe":
    VIBE_WASM_SOURCE_COVERAGE_INVOKE=selfbuild_compile_stage2 scripts/coverage_wasm_source.sh {{entry}}

# Run selfhost workload coverage (lex/parse/print/eval/import smoke)
coverage-selfhost entry="vibe/compiler/selfhost_coverage_run.vibe":
    scripts/coverage_wasm_source.sh {{entry}}

# Run selfhost workload coverage with KPI gate
coverage-selfhost-gate point="23" line="100" branch="20":
    VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE={{point}} VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE={{line}} VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE={{branch}} scripts/coverage_wasm_source.sh vibe/compiler/selfhost_coverage_run.vibe

# Run selfhost suite coverage (selfhost workload + index invoke)
# env: VIBE_SELFHOST_SUITE_COVERAGE_DIR, VIBE_SELFHOST_SUITE_SOURCE_DIR, VIBE_SELFHOST_SUITE_ENTRY_SELFHOST, VIBE_SELFHOST_SUITE_ENTRY_INDEX, VIBE_SELFHOST_SUITE_INDEX_INVOKE, VIBE_SELFHOST_SUITE_EXTRA_ENTRIES, VIBE_SELFHOST_SUITE_ENTRY_EXTRA, VIBE_SELFHOST_SUITE_ENTRY_EXTRA_RUN_TESTS
coverage-selfhost-suite:
    scripts/coverage_selfhost_suite.sh

# Run selfhost suite coverage with KPI gate
# env: VIBE_SELFHOST_SUITE_MIN_POINT_RATE, VIBE_SELFHOST_SUITE_MIN_LINE_RATE, VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE
coverage-selfhost-suite-gate point="36" line="97" branch="30":
    VIBE_SELFHOST_SUITE_MIN_POINT_RATE={{point}} VIBE_SELFHOST_SUITE_MIN_LINE_RATE={{line}} VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE={{branch}} scripts/coverage_selfhost_suite.sh

# Show next branch-focused entries to add from selfhost suite report
# env: VIBE_SELFHOST_SUITE_NEXT_BRANCHES_FORMAT=text|env|json
coverage-selfhost-suite-next-branches report="_build/coverage/selfhost-suite/selfhost_suite.report.json":
    node scripts/coverage_selfhost_suite_next_branches.mjs {{report}} --format {{env_var_or_default("VIBE_SELFHOST_SUITE_NEXT_BRANCHES_FORMAT", "text")}}

# Run branch-focused selfhost suite coverage (adds lexer/printer/eval_builtins/checker tests)
coverage-selfhost-suite-branch:
    VIBE_SELFHOST_SUITE_COVERAGE_DIR=_build/coverage/selfhost-suite-branch VIBE_SELFHOST_SUITE_EXTRA_ENTRIES='{{selfhost_suite_branch_extra_entries}}' scripts/coverage_selfhost_suite.sh

# Run branch-focused selfhost suite coverage with KPI gate
coverage-selfhost-suite-branch-gate point="40" line="93" branch="33":
    VIBE_SELFHOST_SUITE_COVERAGE_DIR=_build/coverage/selfhost-suite-branch VIBE_SELFHOST_SUITE_EXTRA_ENTRIES='{{selfhost_suite_branch_extra_entries}}' VIBE_SELFHOST_SUITE_MIN_POINT_RATE={{point}} VIBE_SELFHOST_SUITE_MIN_LINE_RATE={{line}} VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE={{branch}} scripts/coverage_selfhost_suite.sh

# Run source-level WASM coverage for eval sidecar tests (`<db>.tests/<target>_test.vibe`)
# env: VIBE_EVAL_COVERAGE_DIR, VIBE_WASM_SOURCE_COVERAGE_MODE, VIBE_WASM_SOURCE_COVERAGE_NO_DCE, VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP, VIBE_WASM_SOURCE_COVERAGE_DIR
coverage-eval-sidecar db target:
    scripts/coverage_eval_sidecar.sh {{db}} {{target}}

# Run vibe/prelude coverage from *_test.vibe via wasm source coverage
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

# Verify build --debug and --release produce identical results
test-build-parity:
    scripts/test_build_parity.sh

# Run each fixture in isolated subprocess (detects abort/crash/timeout)
test-fixtures-isolation:
    scripts/test_fixtures_isolation.sh

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

# Build native wasm-only runner CLI (`src/cmd/vibe_wasm`)
build-vibe-wasm:
    moon build --target native src/cmd/vibe_wasm

# Run native wasm-only runner CLI (`compile|run|compare`)
run-vibe-wasm *args:
    moon run --target native src/cmd/vibe_wasm -- {{args}}

# Build wasm line shell package (wasi preview2 imports)
build-shell-wasi-wasm:
    moon build --target wasm src/cmd/vibe_wasi

# Build wasm compiler CLI package (filesystem adapter via src/io)
build-compiler-wasi-wasm:
    moon build --target wasm src/cmd/vibe_compile_wasi

# Build wasm checker CLI package (JSON diagnostics)
build-checker-wasi-wasm:
    moon build --target wasm src/cmd/vibe_check_wasi

# Build wasm wite optimize/wac sidecar CLI package
build-wite-optimize-wasi-wasm:
    moon build --target wasm src/cmd/vibe_wite_optimize_wasi

# Build experimental wasi:http@0.3 adapter component (Rust + wit-bindgen)
build-wasi-http-p3-adapter out="":
    if [ -n "{{out}}" ]; then \
      scripts/build_wasi_http_p3_adapter.sh {{out}}; \
    else \
      scripts/build_wasi_http_p3_adapter.sh; \
    fi

# Probe async P3 adapter compose/serve path (wac plug + wasmtime serve smoke)
probe-wasi-http-p3-compose wac="wac":
    WAC_BIN={{wac}} scripts/probe_wasi_http_p3_compose.sh

# Probe async P3 service-only component (no compose) against wasmtime serve
probe-wasi-http-p3-service-only:
    scripts/probe_wasi_http_p3_service_only.sh

# Run WASI HTTP P3 gate in blocked/strict mode
# env: VIBE_WASI_HTTP_P3_REQUIRE_READY=0|1, VIBE_WASI_HTTP_P3_RUN_COMPOSE=0|1, WAC_BIN=<path>
test-wasi-http-p3-gate:
    scripts/test_wasi_http_p3_blocked_gate.sh

# Run wasm compiler CLI through moon wasm runner
run-compiler-wasi-wasm *args:
    moon run --target wasm src/cmd/vibe_compile_wasi -- {{args}}

# Run wasm checker CLI through moon wasm runner
run-checker-wasi-wasm *args:
    moon run --target wasm src/cmd/vibe_check_wasi -- {{args}}

# Run wasm wite optimize/wac sidecar CLI through moon wasm runner
run-wite-optimize-wasi-wasm *args:
    moon run --target wasm src/cmd/vibe_wite_optimize_wasi -- {{args}}

# Run wasm compiler CLI (wasm-gc backend)
run-compiler-wasi-wasm-gc *args:
    moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm-gc {{args}}

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
    bash -c 'VIBE_CLI_RELEASE=1 source scripts/ensure_native_cli.sh'
    mkdir -p {{bindir}}
    cp {{cli_bin}} {{bindir}}/vibe

# Benchmark wasm execution via wasmtime
bench-wasmtime:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_wasmtime.sh

# Measure wasmtime fixed overhead (CLI one-shot + resident phases)
bench-wasmtime-overhead path='':
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_wasmtime_overhead.sh {{path}}

# Compare interpreter vs wasmtime
bench-compare:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_compare.sh

# Run language bench and collect latency + wasm size KPI in one report
# env: VIBE_BENCH_KPI_N, VIBE_BENCH_KPI_WARMUP, VIBE_BENCH_KPI_BACKEND, VIBE_BENCH_KPI_MAX_PER_US, VIBE_BENCH_KPI_MAX_WASM_BYTES, VIBE_BENCH_KPI_MAX_SCORE, VIBE_BENCH_KPI_DIR, VIBE_BENCH_KPI_REPORT
bench-kpi *paths:
    scripts/bench_kpi.sh {{paths}}

# Full KPI suite (all patterns)
bench-kpi-full:
    scripts/bench_kpi.sh bench/kpi_bench.vibe bench/kpi_bench_large_fn.vibe bench/kpi_bench_strings.vibe bench/kpi_bench_effects.vibe bench/kpi_bench_match.vibe

# Compare wasm js-string vs wasm gc on string-heavy workload
bench-string-compare:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/bench_string_compare.sh

# Benchmark experimental jsonschema validator
bench-jsonschema:
    moon run --target native src/cmd/vibe/main.mbt -- bench vibe/x/jsonschema/bench.vibe

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

# Compare array construction strategies (array_concat vs array_builder)
bench-array-build:
    moon run --target native src/cmd/vibe/main.mbt -- bench bench/bench_array_build_strategies.vibe

# Compare char conversion strategies (char builtins vs string bridge)
bench-char-conversion:
    moon run --target native src/cmd/vibe/main.mbt -- bench bench/bench_char_conversion.vibe

# HTTP request latency benchmark (interpreter, requires network)
# env: VIBE_BENCH_HTTP_N (default 50), VIBE_BENCH_HTTP_WARMUP (default 5)
# Run HTTP E2E tests (requires network, starts test server)
test-http-e2e:
    scripts/test_http_e2e.sh

# Run HTTP WASM tests (fallback + host-import capability/e2e)
test-http-wasm:
    scripts/test_http_wasm_fallback.sh
    scripts/test_http_wasm_host_imports.sh

# Verify compiled backend HTTP policy (auto fallback + forced compiled reject)
test-http-compiled-policy:
    scripts/test_compiled_backend_http_policy.sh

# Run selfhost bootstrap gate (compiled suite + probe smoke + deterministic wasm)
test-selfhost-bootstrap:
    scripts/test_selfhost_bootstrap_gate.sh

# Run quick selfhost cache probe (warm TypeDb reuse smoke)
test-selfhost-cache-probe:
    bash -c 'source scripts/ensure_native_cli.sh'
    VIBE_TEST_BACKEND=interpreter _build/native/debug/build/cmd/vibe/vibe.exe test vibe/compiler/cache_probe_test.vibe

# Run wasm selfbuild gate (stage0 wasm compiler -> stage1 selfhost wasm)
test-selfhost-wasi-selfbuild:
    scripts/test_selfhost_wasi_selfbuild.sh

# Run wasm selfbuild gate with KPI (total time budget)
test-selfhost-wasi-selfbuild-kpi max_total_sec="300":
    VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE=1 VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE=1 VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC={{max_total_sec}} scripts/test_selfhost_wasi_selfbuild.sh

# Run artifact-only selfhost CLI adapter gate (stage1 compiler -> selfhost cli -> sample compile)
test-selfhost-cli-adapter:
    bash scripts/test_selfhost_cli_adapter.sh

test-selfhost-cli-adapter-cache:
    bash scripts/test_selfhost_cli_adapter_cache.sh

# Run artifact-only selfhost core CLI gate (stage1 core wasm -> sample compile)
test-selfhost-cli-core:
    bash scripts/test_selfhost_cli_core.sh

# Verify wasm host runner string/env/args/fs ABI for core wasm execution
test-wasm-vibe-host-runner:
    bash scripts/test_wasm_vibe_host_runner.sh

# Run fixed-path selfhost CLI adapter through wasmtime Preview2 fs only
test-selfhost-cli-fixed-adapter-preview2:
    bash scripts/test_selfhost_cli_fixed_adapter_preview2.sh

# Run string-lift selfhost CLI component through wasmtime Preview2 only
test-selfhost-cli-component-preview2:
    bash scripts/test_selfhost_cli_component_preview2.sh

# Build distributable selfhost Preview2 component package
build-selfhost-cli-preview2-component out="dist/selfhost_cli_preview2.component.wasm" wit="dist/selfhost_cli_preview2.component.wit":
    bash scripts/build_selfhost_cli_preview2_component.sh {{out}} {{wit}}

# Run distributable selfhost Preview2 component package
run-selfhost-cli-preview2-component component input output entry:
    bash scripts/run_selfhost_cli_preview2_component.sh {{component}} {{input}} {{output}} {{entry}}

# Run distributable selfhost Preview2 component package gate
test-selfhost-cli-preview2-package:
    bash scripts/test_selfhost_cli_preview2_package.sh

# Build a distributable selfhost CLI command component (stdin=source, argv[-1]=entry, stdout=wasm)
build-selfhost-cli-command-component out="dist/selfhost_cli_command.component.wasm" wit="dist/selfhost_cli_command.component.wit":
    bash scripts/build_selfhost_cli_command_component.sh {{out}} {{wit}}

# Run distributable selfhost CLI command component gate
test-selfhost-cli-command-component:
    bash scripts/test_selfhost_cli_command_component.sh

# Run host-vs-selfhost smoke gate via command component
test-selfhost-cli-command-parity:
    bash scripts/test_selfhost_cli_command_parity.sh

# Build distributable selfhost CLI direct filesystem component
build-selfhost-cli-direct-component out="dist/selfhost_cli_direct.component.wasm" wit="dist/selfhost_cli_direct.component.wit":
    bash scripts/build_selfhost_cli_direct_component.sh {{out}} {{wit}}

# Run distributable selfhost CLI direct filesystem component
run-selfhost-cli-direct-component component input output entry:
    bash scripts/run_selfhost_cli_direct_component.sh {{component}} {{input}} {{output}} {{entry}}

# Run distributable selfhost CLI direct filesystem component gate
test-selfhost-cli-direct-component:
    bash scripts/test_selfhost_cli_direct_component.sh

# Run host-vs-selfhost parity gate via direct filesystem component
test-selfhost-cli-direct-parity:
    bash scripts/test_selfhost_cli_direct_parity.sh

# Build distributable selfhost check Preview2 component package
build-selfhost-check-preview2-component out="dist/selfhost_check_preview2.component.wasm" wit="dist/selfhost_check_preview2.component.wit":
    bash scripts/build_selfhost_check_preview2_component.sh {{out}} {{wit}}

# Run distributable selfhost check Preview2 component package
run-selfhost-check-preview2-component component input:
    bash scripts/run_selfhost_check_preview2_component.sh {{component}} {{input}}

# Run distributable selfhost check Preview2 component package gate
test-selfhost-check-preview2-package:
    bash scripts/test_selfhost_check_preview2_package.sh

# Build a distributable selfhost check command component (stdin=source, stdout=report)
build-selfhost-check-command-component out="dist/selfhost_check_command.component.wasm" wit="dist/selfhost_check_command.component.wit":
    bash scripts/build_selfhost_check_command_component.sh {{out}} {{wit}}

# Run distributable selfhost check command component gate
test-selfhost-check-command-component:
    bash scripts/test_selfhost_check_command_component.sh

# Run host-vs-selfhost smoke gate via check command component
test-selfhost-check-command-parity:
    bash scripts/test_selfhost_check_command_parity.sh

# Build distributable selfhost check direct filesystem component
build-selfhost-check-direct-component out="dist/selfhost_check_direct.component.wasm" wit="dist/selfhost_check_direct.component.wit":
    bash scripts/build_selfhost_check_direct_component.sh {{out}} {{wit}}

# Run distributable selfhost check direct filesystem component
run-selfhost-check-direct-component component input output:
    bash scripts/run_selfhost_check_direct_component.sh {{component}} {{input}} {{output}}

# Run distributable selfhost check direct filesystem component gate
test-selfhost-check-direct-component:
    bash scripts/test_selfhost_check_direct_component.sh

# Run host-vs-selfhost parity gate via direct check component
test-selfhost-check-direct-parity:
    bash scripts/test_selfhost_check_direct_parity.sh

# Run wasi:http boundary gate (stage0 wasm compiler -> component wit imports)
test-selfhost-wasi-http-boundary:
    scripts/test_selfhost_wasi_http_boundary.sh

# Run selfhost cutover gate (CLI contract + artifact parity)
test-selfhost-cutover:
    scripts/test_selfhost_cutover_gate.sh

# Run bootstrap-only selfhost check parity snapshot gate (stage1 checker diff snapshot)
test-selfhost-check-bootstrap-parity:
    scripts/test_selfhost_check_parity.sh

# Backward-compatible alias for the bootstrap-only parity snapshot gate
test-selfhost-check-parity: test-selfhost-check-bootstrap-parity

# Bootstrap-only selfhost gate bundle (stage1/stage2 artifact health + checker parity)
release-selfhost-bootstrap-gates: test-selfhost-bootstrap test-selfhost-wasi-selfbuild-kpi test-selfhost-check-bootstrap-parity

# Selfhost checker parity across typecheck diagnostic fixtures
test-selfhost-typecheck-fixtures:
    scripts/test_selfhost_typecheck_fixtures.sh

# Selfhost runtime fixture smoke via compiled backend
test-selfhost-runtime-fixtures:
    scripts/test_selfhost_runtime_fixtures.sh

update-selfhost-runtime-fixture-snapshot:
    node scripts/update_selfhost_runtime_fixture_snapshot.mjs

# Selfhost checker parity across warning diagnostic fixtures
test-selfhost-warning-fixtures:
    scripts/test_selfhost_warning_fixtures.sh

bench-http:
    scripts/bench_http.sh

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

# Debug scratch workflow loop (`new -> eval -> finalize -> normalize`)
# env: VIBE_SCRATCH_RUNS, VIBE_SCRATCH_TMP_PARENT, VIBE_SCRATCH_KEEP_SUCCESS,
#      VIBE_SCRATCH_CHECK_MAIN, VIBE_SCRATCH_CLI_BUILD, VIBE_SCRATCH_CLI_BIN
debug-scratch-workflow:
    scripts/debug_scratch_workflow.sh

# Benchmark vibe normalize on all .vibe files
# env: VIBE_BENCH_NORMALIZE_RUNS (default: 1)
bench-normalize:
    scripts/bench_normalize.sh

# Benchmark vibe normalize (release build)
bench-normalize-release:
    scripts/bench_normalize.sh --release

# Benchmark symbol index + LSIF backend
bench-symbol-index:
    moon bench -p benches -f symbol_index_bench.mbt

# Benchmark advanced graph index PoC (search + remote delta apply)
bench-advanced-graph:
    moon bench -p benches -f advanced_graph_bench.mbt

# Benchmark typechecker and ripple type-cache behavior
bench-typechecker:
    moon bench -p benches -f checker_bench.mbt

# Compare host vs selfhost compile/check speed on the same case set
# env: VIBE_SELFHOST_PERF_RUNS, VIBE_SELFHOST_PERF_CASES_FILE, VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO, VIBE_SELFHOST_PERF_MAX_CHECK_RATIO, VIBE_SELFHOST_PERF_WASM_PROFILE
bench-selfhost-perf *paths:
    scripts/bench_selfhost_perf.sh {{paths}}

bench-selfhost-cache-probe:
    scripts/bench_selfhost_cache_probe.sh

bench-selfhost-loader-hotspots:
    scripts/bench_selfhost_loader_hotspots.sh

# KPI gate: selfhost perf ratio thresholds (host vs selfhost, same case set)
# Default baseline uses debug selfhost wasm with 3-run median; switch with VIBE_SELFHOST_PERF_WASM_PROFILE=release when comparing packaging artifacts.
# Current stable debug baseline is around compile ~5x / check ~2-4x slower than host.
# Keep modest headroom here and tighten as hot paths improve.
# env override: VIBE_SELFHOST_PERF_RUNS / VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO / VIBE_SELFHOST_PERF_MAX_CHECK_RATIO / VIBE_SELFHOST_PERF_WASM_PROFILE
test-selfhost-perf-gate runs="3" max_compile_ratio="8.0" max_check_ratio="5.0" cases_file="bench/selfhost_perf/kpi_cases.txt":
    VIBE_SELFHOST_PERF_RUNS={{runs}} VIBE_SELFHOST_PERF_CASES_FILE={{cases_file}} VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO={{max_compile_ratio}} VIBE_SELFHOST_PERF_MAX_CHECK_RATIO={{max_check_ratio}} scripts/bench_selfhost_perf.sh

# Product bundle-size monitor (live examples/ + use-case importers).
# This captures product-facing size drift, including source edits.
# Default importer mode is runtime-first (`--wasm`/`--wasm-js-string`).
# Set `VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1` to add no-dce diagnostics.
# Set `VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1` to include vibe/prelude module surfaces.
bench-bundle-size:
    scripts/bench_bundle_size.sh

# Alias: explicit product monitor task name
bench-bundle-size-product:
    scripts/bench_bundle_size.sh

# Update product bundle-size golden budgets
bench-bundle-size-update:
    scripts/bench_bundle_size.sh --update

# Alias: explicit product monitor update task name
bench-bundle-size-product-update:
    scripts/bench_bundle_size.sh --update

# Compiler bundle-size guard (fixed fixtures + importer cases).
# This isolates compiler/codegen regressions from live examples changes.
bench-bundle-size-compiler:
    scripts/bench_compiler_bundle_size.sh

# Update compiler bundle-size golden budget
bench-bundle-size-compiler-update:
    scripts/bench_compiler_bundle_size.sh --update

# Run wasm bundle-size monitoring set:
# - compiler guard: strict (always gating)
# - product monitor: non-fatal by default
bench-bundle-size-monitor:
    scripts/monitor_wasm_bundle_size.sh

# Strict monitor mode: fail if product monitor regresses too
bench-bundle-size-monitor-strict:
    VIBE_WASM_BUNDLE_MONITOR_STRICT_PRODUCT=1 scripts/monitor_wasm_bundle_size.sh

# Update std-focused benchmark baselines (bundle-size + KPI snapshots)
bench-std-baseline-update:
    VIBE_BUNDLE_BENCH_INCLUDE_STD_SURFACES=1 VIBE_BUNDLE_BENCH_INCLUDE_IMPORTER_NO_DCE=1 scripts/bench_bundle_size.sh --update
    VIBE_BENCH_KPI_BACKEND=compiled VIBE_BENCH_KPI_REPORT=bench/golden/kpi_wasm.tsv scripts/bench_kpi.sh bench/kpi_bench.vibe bench/kpi_bench_large_fn.vibe bench/kpi_bench_strings.vibe bench/kpi_bench_effects.vibe bench/kpi_bench_match.vibe
    VIBE_BENCH_KPI_BACKEND=interpreter VIBE_BENCH_KPI_REPORT=bench/golden/kpi_interpreter.tsv scripts/bench_kpi.sh bench/kpi_bench.vibe bench/kpi_bench_large_fn.vibe bench/kpi_bench_strings.vibe bench/kpi_bench_effects.vibe bench/kpi_bench_match.vibe

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

# Validate moon info regeneration idempotency and deny-warn check compatibility
test-moon-info-regen:
    bash scripts/test_moon_info_regen.sh

# Clean build artifacts
clean:
    moon clean

# E2E tests for Component Model and WIT
test-component-e2e:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/test_component_e2e.sh

# WASI P3 E2E: compile .vibe → compose-p3 → validate → wasmtime serve → curl
# Requires: wasmtime (v44+ for serve), wasm-tools, cargo (for Rust adapter build)
# env: WASMTIME_BIN (override wasmtime binary), VIBE_P3_E2E_PORT (default 18799)
test-wasi-p3-e2e:
    scripts/test_wasi_p3_e2e.sh

# WASI P3 E2E with submodule wasmtime v44 (full serve test)
test-wasi-p3-e2e-v44:
    WASMTIME_BIN=deps/wasmtime/target/release/wasmtime scripts/test_wasi_p3_e2e.sh

# WASI P3 blocked gate (probe service-only component build + optional serve)
test-wasi-p3-blocked-gate:
    VIBE_WASI_HTTP_P3_REQUIRE_READY=0 VIBE_WASI_HTTP_P3_RUN_COMPOSE=0 scripts/test_wasi_http_p3_blocked_gate.sh

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

# Test `vibe run` and `vibe_wasm run/compare` consistency
test-vibe-wasm-compare:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/test_vibe_wasm_compare.sh

# E2E: compile .vibe → .wasm and run with wasmtime (general language features)
test-wasm-compile-wasmtime:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/test_wasm_compile_wasmtime.sh

# Show resolved wasmtime binary for current env selection
show-wasmtime-bin:
    VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} scripts/wasmtime_bin.sh

# Show resolved wasmtime runtime flag env values used by scripts/wasmtime_run.sh
show-wasmtime-flags:
    echo "VIBE_WASMTIME_WASM_FLAGS={{vibe_wasmtime_wasm_flags}}"
    echo "VIBE_WASMTIME_WASI_FLAGS={{vibe_wasmtime_wasi_flags}}"

# Run minimal WASI Threads probe module (requires wasmtime + wasm-tools)
experimental_wasi_threads_probe:
    VIBE_WASMTIME_WASM_FLAGS="{{vibe_wasmtime_wasm_flags}}" VIBE_WASMTIME_WASI_FLAGS="{{vibe_wasmtime_wasi_flags}}" VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} src/x/threads/run_probe.sh

# Backward-compatible alias
wasi-threads-probe: experimental_wasi_threads_probe

# Run CM async probe (concurrency-support + component-model-async on current platform)
probe-cm-async:
    VIBE_USE_WASMTIME_SUBMODULE={{vibe_use_wasmtime_submodule}} src/x/cm_async/run_probe.sh

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
experimental_wasmtime_stack_switching file *args:
    container run --platform linux/amd64 -v $(pwd):/work -v /tmp:/tmp rust:bookworm bash -c '\
      curl -sSf https://wasmtime.dev/install.sh | bash >/dev/null 2>&1 && \
      export PATH="$HOME/.wasmtime/bin:$PATH" && \
      wasmtime run -W stack-switching=y -W exceptions=y -W function-references=y {{args}} /work/{{file}}'

# Backward-compatible alias
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

# Precompile all vibe modules to dist/**/*.wasm
precompile:
    bash -c 'source scripts/ensure_native_cli.sh'
    mkdir -p dist/std dist/path dist/std/threads dist/fs dist/socket dist/http dist/collection dist/json dist/sha1 dist/x dist/x/args
    _build/native/debug/build/cmd/vibe/vibe.exe precompile vibe/prelude vibe/path vibe/prelude/threads vibe/fs vibe/socket vibe/http vibe/collection vibe/json vibe/sha1 vibe/x vibe/x/args --out-dir "$(pwd)/dist" --wasm

# Create a new ADR (usage: just adr "タイトル slug")
adr title:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="docs/adr"
    last=$(ls "$dir"/[0-9]*.md 2>/dev/null | sort -r | head -1 | sed 's|.*/0*\([0-9][0-9]*\).*|\1|' || echo "")
    if [ -z "$last" ]; then last="-1"; fi
    next=$(printf "%04d" $(( last + 1 )))
    slug=$(echo "{{title}}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
    file="$dir/${next}-${slug}.md"
    today=$(date +%Y-%m-%d)
    sed -e "s/NNNN/${next}/g" -e "s/YYYY-MM-DD/${today}/g" -e "s/タイトル/{{title}}/g" "$dir/TEMPLATE.md" > "$file"
    echo "Created: $file"

# Normalize all .vibe files (fix mode)
vibe-normalize:
    scripts/vibe_normalize_all.sh

# Normalize, skipping files whose hash matches cache
vibe-normalize-cached:
    scripts/vibe_normalize_all.sh --skip-cached

# Verify all .vibe files are already normalized (CI / pre-commit)
vibe-normalize-check:
    scripts/vibe_normalize_all.sh --check

# Pre-release selfhost gate bundle
release-selfhost-gates: check-selfhost-bundle-sync test-selfhost-cache-probe test-selfhost-bootstrap test-selfhost-wasi-selfbuild-kpi test-selfhost-cli-core test-selfhost-cli-component-preview2 test-selfhost-cli-preview2-package test-selfhost-cli-command-component test-selfhost-cli-command-parity test-selfhost-cli-direct-component test-selfhost-cli-direct-parity test-selfhost-check-preview2-package test-selfhost-check-command-component test-selfhost-check-command-parity test-selfhost-check-direct-component test-selfhost-check-direct-parity test-selfhost-cutover test-golden-wat

# Pre-release check (includes selfhost gates + wasm bundle-size monitor)
release-check: fmt info check test-full vibe-normalize bench-bundle-size-monitor release-selfhost-gates

# Alias for teams used to `check-release`
check-release: release-check

# Start playground dev server (builds wasm first)
playground-dev: build-integration-deno-wasm
    cp _build/wasm-gc/release/build/lib/lib.wasm playground/public/vibe-runtime.wasm
    cd playground && pnpm dev

# Build playground for GitHub Pages
playground-build: build-integration-deno-wasm
    cp _build/wasm-gc/release/build/lib/lib.wasm playground/public/vibe-runtime.wasm
    cd playground && VITE_BASE=/vibe-lang/ pnpm build

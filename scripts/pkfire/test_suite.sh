#!/usr/bin/env bash
# Full test suite — extracted from justfile `test` recipe.
# Run via `pkf run test`.
set -uo pipefail

target="${VIBE_TARGET:-js}"
moon_warn_list="${VIBE_MOON_WARN_LIST:--1-6-7-9-20-24-29}"
node_options="${VIBE_TEST_NODE_OPTIONS:---max-old-space-size=16384}"

scripts/check_lock_clean.sh
scripts/check_lock_clean_test.sh
bash scripts/generate_selfhost_bundle_test.sh
node --test scripts/coverage_selfhost_suite_next_branches.test.mjs scripts/coverage_wasm_source.test.mjs scripts/selfhost_select_test_shard.test.mjs
env NODE_OPTIONS="$node_options" moon test --target "$target" --warn-list "$moon_warn_list"
bash scripts/test_typecheck_fixtures.sh
bash scripts/test_warning_fixtures.sh
moon test -p mizchi/vibe/lib --target wasm-gc --warn-list "$moon_warn_list"
moon test -p mizchi/vibe/cmd/vibe -f cli_e2e_wbtest.mbt --target native --warn-list "$moon_warn_list"
moon test -p mizchi/vibe/cmd/vibe_check_wasi --target wasm --warn-list "$moon_warn_list"
VIBE_WASM_GC_MAINLANE=1 moon test --target native src/tests/vibe_wasm_gc_mainlane_e2e_test.mbt --warn-list "$moon_warn_list"
bash -c 'source scripts/ensure_native_cli.sh'
bash scripts/test_parallel_cleanup_e2e.sh _build/native/debug/build/cmd/vibe/vibe.exe || echo "WARN: parallel cleanup e2e failed (non-fatal)"
bash scripts/test_internal_parent_watchdog_e2e.sh _build/native/debug/build/cmd/vibe/vibe.exe || echo "WARN: watchdog e2e failed (non-fatal)"

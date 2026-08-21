#!/usr/bin/env bash
# Selfhost release gate shards — extracted from justfile `ci-gates-shard`.
# Usage: scripts/pkfire/gates_shard.sh <bootstrap|bootstrap-core|cli|check|coverage>
#
# Dead-reference cleanup (same pattern as #851 / #821): every script a shard
# invokes must exist in-tree — a missing file kills the shard at that line
# under `set -e` and everything after it silently never runs. The following
# referenced scripts were retired with the MoonBit host (#594) or never
# committed, and their invocations are dropped:
#   test_selfhost_bootstrap_gate.sh, test_selfhost_wasi_selfbuild.sh
#   (bootstrap/selfbuild), test_selfhost_check_command_parity.sh,
#   test_selfhost_check_direct_parity.sh, test_selfhost_check_parity.sh,
#   test_selfhost_wasi_http_boundary.sh, test_vibe_check_selfhost_byte_parity.sh,
#   test_golden_wat.sh (check), bench_selfhost_perf.sh (coverage),
#   test_selfhost_corpus_gate.sh (corpus).
# The `selfbuild` and `corpus` shards had nothing left and were removed.
set -euo pipefail

shard="${1:?missing shard argument: bootstrap|bootstrap-core|cli|check|coverage}"

case "$shard" in
  bootstrap-core)
    # The generated artifacts are build outputs, not tracked files, so this
    # shard produces them instead of diffing them against committed copies.
    bash scripts/ensure_generated.sh
    ;;
  bootstrap)
    bash scripts/ensure_generated.sh
    # Live replacement for the retired MoonBit-host bootstrap/selfbuild gates:
    # the seed->stage1->stage2(->stage3 fixpoint) build is exactly
    # what those gates existed to protect.
    bash scripts/compiler_gate.sh
    ;;
  cli)
    # Library `vibe test` smoke (selfhost-CLI-compilable subset; covers lib/@vibex/wasm and
    # lib/@vibe/builtin — the selfhost-only gate doesn't reach these).
    bash scripts/test_vibe_library.sh
    # #821: the following gate scripts were referenced here but NEVER committed
    # (no git history), so this shard died at the first missing file under
    # `set -e` and everything after it silently never ran:
    #   test_selfhost_cli_component_preview2.sh, test_selfhost_cli_command_parity.sh,
    #   test_selfhost_cli_direct_parity.sh, test_selfhost_cutover_gate.sh
    # The split CLI core is a supported entry point used by vibe_cli.sh. Keep
    # its build and command surface in the CLI shard so its effect row and
    # generated-source prerequisites cannot rot unnoticed (#2148).
    bash scripts/test_cli_core.sh
    bash scripts/test_cli_preview2_package.sh
    bash scripts/test_cli_command_component.sh
    bash scripts/test_cli_direct_component.sh
    bash scripts/test_vibe_run_single_invoke.sh
    bash scripts/test_rc_bootstrap.sh
    bash scripts/test_async_component_gate.sh
    bash scripts/test_wasi_http_p3_full_gate.sh
    ;;
  check)
    bash scripts/test_check_preview2_package.sh
    bash scripts/test_check_command_component.sh
    bash scripts/test_check_direct_component.sh
    ;;
  coverage)
    # The thresholds live in ONE place: the defaults in
    # scripts/coverage_suite.sh (every one of them is env-overridable there).
    # This shard used to duplicate them with a "keep in sync" comment and then
    # drifted anyway -- it still pinned the pre-2026-07-25 rate floors
    # (POINT 20 / BRANCH 7) after that rebaseline lowered them to 13/6 for
    # actuals of 14.07%/6.35%, so running the shard failed on numbers CI (which
    # invokes coverage_suite.sh directly) was passing. Don't re-add overrides
    # here; change the defaults at the source instead.
    scripts/coverage_suite.sh
    ;;
  *)
    echo "unknown shard: $shard (expected: bootstrap|bootstrap-core|cli|check|coverage)" >&2
    exit 1
    ;;
esac

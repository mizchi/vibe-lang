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
    # lib/@vibe/prelude — the selfhost-only gate doesn't reach these).
    bash scripts/test_vibe_library.sh
    # #821: the following gate scripts were referenced here but NEVER committed
    # (no git history), so this shard died at the first missing file under
    # `set -e` and everything after it silently never ran:
    #   test_selfhost_cli_component_preview2.sh, test_selfhost_cli_command_parity.sh,
    #   test_selfhost_cli_direct_parity.sh, test_selfhost_cutover_gate.sh
    # test_cli_core.sh exists but depends on build_cli_core.sh
    # which was also never committed (recorded in #766 / PR #804). Restore each
    # from its spec contract before re-adding to this list.
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
    # Rebaselined 2026-07-05 (allowlist 110 -> 224 diluted the rates while
    # absolute covered counts rose ~5x); rebaselined again 2026-07-15 (#801,
    # a loader-cache fix let a previously-crashing bench test start
    # contributing its (below-average) coverage ratio); rebaselined again
    # 2026-07-15 (#847, mechanical index-facade reroutes grew the
    # whole-program-merge denominator ~9.8% while absolute hit count rose)
    # — keep in sync with the defaults in scripts/coverage_suite.sh.
    VIBE_SUITE_MIN_POINT_RATE="${VIBE_SUITE_MIN_POINT_RATE:-20}" \
    VIBE_SUITE_MIN_LINE_RATE="${VIBE_SUITE_MIN_LINE_RATE:-97}" \
    VIBE_SUITE_MIN_BRANCH_RATE="${VIBE_SUITE_MIN_BRANCH_RATE:-7}" \
    VIBE_SUITE_MIN_FN_HIT="${VIBE_SUITE_MIN_FN_HIT:-12000}" \
    VIBE_SUITE_MIN_BRANCH_HIT="${VIBE_SUITE_MIN_BRANCH_HIT:-29000}" \
    scripts/coverage_suite.sh
    ;;
  *)
    echo "unknown shard: $shard (expected: bootstrap|bootstrap-core|cli|check|coverage)" >&2
    exit 1
    ;;
esac

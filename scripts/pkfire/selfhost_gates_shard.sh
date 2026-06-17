#!/usr/bin/env bash
# Selfhost release gate shards — extracted from justfile `ci-selfhost-gates-shard`.
# Usage: scripts/pkfire/selfhost_gates_shard.sh <bootstrap|bootstrap-core|selfbuild|cli|check|coverage|corpus>
set -euo pipefail

shard="${1:?missing shard argument: bootstrap|bootstrap-core|selfbuild|cli|check|coverage|corpus}"

case "$shard" in
  bootstrap-core)
    bash scripts/check_selfhost_bundle_sync.sh
    scripts/test_selfhost_bootstrap_gate.sh
    ;;
  selfbuild)
    VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE=1 \
    VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE=1 \
    VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC="${VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC:-300}" \
    scripts/test_selfhost_wasi_selfbuild.sh
    ;;
  bootstrap)
    bash scripts/check_selfhost_bundle_sync.sh
    scripts/test_selfhost_bootstrap_gate.sh
    VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE=1 \
    VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE=1 \
    VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC="${VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC:-300}" \
    scripts/test_selfhost_wasi_selfbuild.sh
    ;;
  cli)
    bash scripts/test_selfhost_cli_core.sh
    bash scripts/test_selfhost_cli_component_preview2.sh
    bash scripts/test_selfhost_cli_preview2_package.sh
    bash scripts/test_selfhost_cli_command_component.sh
    bash scripts/test_selfhost_cli_command_parity.sh
    bash scripts/test_selfhost_cli_direct_component.sh
    bash scripts/test_selfhost_cli_direct_parity.sh
    scripts/test_selfhost_cutover_gate.sh
    bash scripts/test_selfhost_rc_bootstrap.sh
    bash scripts/test_selfhost_async_component_gate.sh
    bash scripts/test_wasi_http_p3_body_gate.sh
    ;;
  check)
    bash scripts/test_selfhost_check_preview2_package.sh
    bash scripts/test_selfhost_check_command_component.sh
    bash scripts/test_selfhost_check_command_parity.sh
    bash scripts/test_selfhost_check_direct_component.sh
    bash scripts/test_selfhost_check_direct_parity.sh
    ./scripts/test_selfhost_wasi_http_boundary.sh
    VIBE_CHECK_PARITY_REQUIRE_PARITY=1 ./scripts/test_selfhost_check_parity.sh
    bash scripts/test_vibe_check_selfhost_byte_parity.sh
    scripts/test_golden_wat.sh
    ;;
  coverage)
    VIBE_SELFHOST_PERF_COMPILER_KIND=cli-core \
    VIBE_SELFHOST_PERF_CHECKER_KIND=cli-core \
    VIBE_SELFHOST_PERF_COMPILE_DAEMON=1 \
    VIBE_SELFHOST_PERF_CHECK_DAEMON=1 \
    VIBE_SELFHOST_PERF_RUNS=1 \
    VIBE_SELFHOST_PERF_CASES_FILE=bench/selfhost_perf/kpi_cases.txt \
    VIBE_SELFHOST_PERF_MAX_COMPILE_RATIO=2.5 \
    VIBE_SELFHOST_PERF_MAX_CHECK_RATIO=0.8 \
    ./scripts/bench_selfhost_perf.sh
    VIBE_SELFHOST_SUITE_MIN_POINT_RATE="${VIBE_SELFHOST_SUITE_MIN_POINT_RATE:-36}" \
    VIBE_SELFHOST_SUITE_MIN_LINE_RATE="${VIBE_SELFHOST_SUITE_MIN_LINE_RATE:-97}" \
    VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE="${VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE:-30}" \
    scripts/coverage_selfhost_suite.sh
    ;;
  corpus)
    # Full-corpus selfhost compile gate (#492): every corpus .vibe must
    # compile through the self-hosted compiler with no REAL language/checker
    # gaps. `--gate` exits non-zero only on REAL gaps (MODE/TRIAGE harness
    # artifacts do not trip it). Tracks selfhost expressiveness regressions on
    # the path to dropping the MoonBit implementation.
    bash scripts/test_selfhost_corpus_gate.sh --gate
    ;;
  *)
    echo "unknown shard: $shard (expected: bootstrap|bootstrap-core|selfbuild|cli|check|coverage|corpus)" >&2
    exit 1
    ;;
esac

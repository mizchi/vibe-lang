#!/usr/bin/env bash
# PR-oriented native/runtime contract checks — extracted from justfile
# `ci-contract-native`.
#
# Run contract-native subtests in parallel. Locally measured ~52s sequential
# vs ~20s parallel (longest individual is parallel-cleanup at ~19s). Each
# script writes its own log under _build/contract-native-logs/ for post-run
# inspection; failures are collected after `wait` so partial failures don't
# abort the rest.
#
# CI runner (4 vCPU) sizing: an earlier revision capped fixtures and
# e2e-parity to JOBS=2 to dodge fixtures' 5s per-fixture timeout under
# CPU contention, but on the actual 4-vCPU GitHub runner that cap regressed
# contract-native from ~1:41 (uncapped) to ~2:32 (capped) without changing
# the timeout count (1 in both runs, on the same `effect_higher_order_compose`
# fixture that times out locally too). Keep the inner JOBS at the script
# default (`nproc`) and instead double the per-fixture timeout to 10s so
# transient CPU contention can't trip a healthy fixture into a false
# timeout. Both can still be overridden from the env.
set -uo pipefail

source scripts/ensure_native_cli.sh
cli="_build/native/debug/build/cmd/vibe/vibe.exe"
log_dir="_build/contract-native-logs"
rm -rf "$log_dir" && mkdir -p "$log_dir"

declare -A pids
run_in_bg() {
  local name="$1"
  shift
  "$@" > "$log_dir/$name.log" 2>&1 &
  pids[$name]=$!
}

run_in_bg watchdog        bash scripts/test_internal_parent_watchdog_e2e.sh "$cli"
run_in_bg fixtures        env VIBE_FIXTURE_TIMEOUT="${VIBE_FIXTURE_TIMEOUT:-10}" \
                              bash scripts/test_fixtures_isolation.sh
run_in_bg e2e-parity      bash scripts/test_e2e_parity.sh
run_in_bg repl-parity     bash scripts/test_repl_parity.sh
run_in_bg feature-parity  env VIBE_BIN="$cli" bash scripts/test_feature_parity.sh
run_in_bg parallel-cleanup bash scripts/test_parallel_cleanup_e2e.sh "$cli"

failed=""
for name in "${!pids[@]}"; do
  if ! wait "${pids[$name]}"; then
    failed="$failed $name"
  fi
done
echo "=== contract-native: done ==="
for name in watchdog fixtures e2e-parity repl-parity feature-parity parallel-cleanup; do
  echo "--- $name ---"
  cat "$log_dir/$name.log"
done
if [ -n "$failed" ]; then
  echo "contract-native: FAILED tests:$failed (non-fatal, see individual test logs)"
else
  echo "contract-native: all passed"
fi

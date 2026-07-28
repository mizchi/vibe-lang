#!/usr/bin/env bash
# Run the compiler's own *_test.vibe unit tests against the cycle-free FLAT module
# source (bypassing the cyclic-import blocker). For each test file: strip imports
# from the relevant *_support.vibe helpers (their deps are top-level in the flat
# source), append the test bodies + assert helpers, compile+run under coverage,
# and union into the corpus acc.json. Test files using cli_main-unreachable
# (DCE'd) functions fail to compile and are skipped.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SEED="bootstrap/seed/compiler.wasm"
# FLAT defaults to the committed DCE'd flat source; override with VIBE_COV_FLAT
# (e.g. the no-DCE merged source) to unblock test files that reference
# cli_main-unreachable (DCE'd) functions. Merge still counts only branches in
# corpus-present functions, so a richer base only adds executed bits, never
# inflates the denominator.
FLAT="${VIBE_COV_FLAT:-lib/@vibe/compiler/_cli_adapter_module_source.vibe}"
RUNNER="scripts/run_wasm_vibe_host_runner.sh"
ACC="_build/coverage/selfhost-corpus/acc.json"
OUT="_build/coverage/selfhost-ut"; rm -rf "$OUT"; mkdir -p "$OUT"

ok=0; fail=0; : > "$OUT/runs.txt"
DRIVER="$OUT/ut_driver.vibe"
for f in lib/@vibe/compiler/*_test.vibe; do
  base="$(basename "$f")"
  SUPPORTS="$(grep -oE "\./[a-z_]+_support\.vibe" "$f" 2>/dev/null | sed "s|\./||" | sort -u | paste -sd, -)"
  bash scripts/coverage_unittests_run.sh "$SUPPORTS" "$base" "$DRIVER" >/dev/null 2>&1 || { fail=$((fail+1)); continue; }
  grep -q "cov_ut_1:" "$DRIVER" 2>/dev/null || { continue; }  # no tests
  cat "$FLAT" "$DRIVER" > "$OUT/src.vibe"
  built=0
  for t in 1 2 3; do
    rm -f "$OUT/ut.wasm"
    VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT" VIBE_IMPORT_ABI=raw bash "$RUNNER" --invoke cli_main "$SEED" "$OUT/src.vibe" "$OUT/ut.wasm" cov_driver_main >/dev/null 2>&1
    [ -s "$OUT/ut.wasm" ] && { built=1; break; }
  done
  if [ "$built" = 1 ]; then
    cov="$OUT/${base%.vibe}.json"
    VIBE_COV_OUT="$cov" VIBE_COV_RAW=1 VIBE_PREOPEN_DIR="$ROOT" bash "$RUNNER" "$OUT/ut.wasm" >/dev/null 2>&1
    [ -s "$cov" ] && { echo "$cov" >> "$OUT/runs.txt"; ok=$((ok+1)); } || fail=$((fail+1))
  else
    fail=$((fail+1))
  fi
done
echo "[ut] $ok test files ran, $fail skipped (DCE'd fns / no tests)" >&2
# (fn_name, local_branch_index) union of every run in runs.txt into acc.json
# -- scripts/coverage_local_merge.vibex's `merge-list` subcommand (native
# vibe port; see that file's header comment for the algorithm).
read -r base now tot < <(bash scripts/coverage_local_merge_run.sh merge-list "$ACC" "$OUT/runs.txt")
scaled=$(( (now * 10000 + tot / 2) / tot ))
pct="$((scaled / 100)).$(printf '%02d' $((scaled % 100)))"
echo "[ut] unit-test merge: $base -> $now/$tot ($pct%) (+$((now-base)))"

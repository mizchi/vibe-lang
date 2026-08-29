#!/usr/bin/env bash
# Function-level coverage for the selfhost compiler (#cov).
#
# Builds an INSTRUMENTED copy of the compiler (each user function gets a 1-byte
# hit flag in a reserved memory region; a `vibe_cov` custom section records the
# base/count + function names), runs it on a workload, and reports which
# compiler functions executed.
#
#   scripts/coverage_fn.sh                 # workload: self-compile the compiler (default)
#   scripts/coverage_fn.sh path/to/foo.vibe  # workload: compile foo.vibe (FS mode)
#   VIBE_COV_SHOW_MISSED=1 scripts/coverage_fn.sh   # also list missed functions
#
# Moon-free: uses the committed seed compiler + the Rust/node runner. The seed
# must support VIBE_COVERAGE (bumped with the coverage feature). Output:
#   _build/coverage/selfhost-fn/compiler_cov.wasm   instrumented compiler
#   _build/coverage/selfhost-fn/report.json         {total,hit,missed,rate,hit_fns,missed_fns}
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SEED="${VIBE_COV_SEED:-$ROOT_DIR/bootstrap/seed/compiler.wasm}"
FLAT="$ROOT_DIR/lib/@vibe/compiler/_cli_adapter_module_source.vibe"
OUT_DIR="${VIBE_COV_DIR:-$ROOT_DIR/_build/coverage/selfhost-fn}"
COMPILER_COV="$OUT_DIR/compiler_cov.wasm"
REPORT="$OUT_DIR/report.json"
RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"

[ -s "$SEED" ] || { echo "coverage_selfhost_fn: seed not found: $SEED" >&2; exit 1; }
[ -s "$FLAT" ] || { echo "coverage_selfhost_fn: flat compiler source not found: $FLAT" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# 1. Produce the instrumented compiler (compile the flat compiler source under
#    VIBE_COVERAGE=1, via the default source-compile path).
echo "[coverage_selfhost_fn] building instrumented compiler ..." >&2
VIBE_COVERAGE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
  bash "$RUNNER" --invoke cli_main "$SEED" \
  "$(realpath --relative-to="$ROOT_DIR" "$FLAT")" \
  "$(realpath --relative-to="$ROOT_DIR" "$COMPILER_COV")" \
  cli_main
[ -s "$COMPILER_COV" ] || { echo "coverage_selfhost_fn: instrumented compiler not produced (seed lacks VIBE_COVERAGE?)" >&2; exit 1; }

# 2. Run the instrumented compiler on the workload.
workload="${1:-}"
sample_out="$OUT_DIR/workload.out.wasm"
if [ -z "$workload" ]; then
  # Default workload: self-compile the whole compiler source (default path).
  echo "[coverage_selfhost_fn] workload: self-compile the compiler source" >&2
  VIBE_COV_OUT="$REPORT" VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    VIBE_INTERNAL_TRUSTED_SOURCE=1 bash "$RUNNER" --invoke cli_main "$COMPILER_COV" \
    "$(realpath --relative-to="$ROOT_DIR" "$FLAT")" \
    "$(realpath --relative-to="$ROOT_DIR" "$sample_out")" \
    cli_main
else
  echo "[coverage_selfhost_fn] workload: compile $workload (FS mode)" >&2
  VIBE_COV_OUT="$REPORT" VIBE_FS_COMPILE=1 VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_IMPORT_ABI=raw \
    bash "$RUNNER" --invoke cli_main "$COMPILER_COV" \
    "$workload" "$(realpath --relative-to="$ROOT_DIR" "$sample_out")" \
    _start
fi
[ -s "$REPORT" ] || { echo "coverage_selfhost_fn: no report produced" >&2; exit 1; }

# 3. Summarize.
python3 - "$REPORT" "${VIBE_COV_SHOW_MISSED:-0}" "${VIBE_COV_SHOW_BRANCH_GAPS:-0}" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
show_missed = sys.argv[2] == "1"
show_branch_gaps = sys.argv[3] == "1"
print(f"[coverage_selfhost_fn] {r['hit']}/{r['total']} functions hit ({r['rate']*100:.2f}%), {r['missed']} missed")
b = r.get("branch")
if b:
    print(f"[coverage_selfhost_fn] {b['hit']}/{b['total']} branches taken ({b['rate']*100:.2f}%), {b['missed']} not taken")
if show_missed:
    print("missed functions:")
    for nm in r["missed_fns"]:
        print(f"  {nm}")
if show_branch_gaps and b:
    print("top functions with untaken branches:")
    for g in b["top_gaps"]:
        print(f"  {g['fn']}: {g['taken']}/{g['total']} taken")
PY
echo "[coverage_selfhost_fn] report: $REPORT" >&2

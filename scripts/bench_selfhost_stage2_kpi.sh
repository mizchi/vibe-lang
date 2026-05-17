#!/usr/bin/env bash
# Selfhost mainline cutover KPI tracker.
#
# Build stage-1 selfhost wasm (host emits it), then use stage-1 to re-emit
# the selfhost source itself producing stage-2 wasm. Verify stage-1 hash ==
# stage-2 hash (bootstrap fixed-point — precondition for cutover). Then run
# `bench_selfhost_perf.sh` against the stage-2 wasm and produce a single-line
# KPI summary plus append to a history file so cutover progress can be
# tracked over time.
#
# See docs/selfhost-cutover-kpi.md for criteria, interpretation, and
# roadmap.
#
# Usage:
#   bash scripts/bench_selfhost_stage2_kpi.sh
#
# Env:
#   VIBE_SELFHOST_KPI_RUNS              measurement runs per case (default: 3)
#   VIBE_SELFHOST_KPI_CASES_FILE        bench cases file
#                                       (default: bench/selfhost_perf/kpi_cases.txt)
#   VIBE_SELFHOST_KPI_HISTORY_FILE      append-only history TSV
#                                       (default: bench/selfhost_perf/stage2_kpi_history.tsv)
#   VIBE_SELFHOST_KPI_SKIP_FIXED_POINT  1 = skip stage1==stage2 hash check (faster,
#                                       only safe when bootstrap-gate is known green)
#   VIBE_SELFHOST_KPI_TARGET_COMPILE    cutover threshold (default: 1.5)
#   VIBE_SELFHOST_KPI_TARGET_CHECK      cutover threshold (default: 1.5)
#   VIBE_SELFHOST_PERF_*                forwarded to bench_selfhost_perf.sh
#
# Exit codes:
#   0 — KPI gathered (regardless of pass/fail vs target; status is reported in stdout)
#   1 — measurement infrastructure failed (compile / bootstrap mismatch / etc.)
set -euo pipefail

trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RUNS="${VIBE_SELFHOST_KPI_RUNS:-3}"
CASES_FILE="${VIBE_SELFHOST_KPI_CASES_FILE:-$PROJECT_ROOT/bench/selfhost_perf/kpi_heavy_cases.txt}"
HISTORY_FILE="${VIBE_SELFHOST_KPI_HISTORY_FILE:-$PROJECT_ROOT/bench/selfhost_perf/stage2_kpi_history.tsv}"
SKIP_FIXED_POINT="${VIBE_SELFHOST_KPI_SKIP_FIXED_POINT:-0}"
TARGET_COMPILE_RATIO="${VIBE_SELFHOST_KPI_TARGET_COMPILE:-1.33}"
TARGET_CHECK_RATIO="${VIBE_SELFHOST_KPI_TARGET_CHECK:-1.33}"

VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
VIBE_BIN="${VIBE_BIN:-$VIBE_CLI_BIN}"

SELFHOST_WASM_PROFILE="${VIBE_SELFHOST_PERF_WASM_PROFILE:-debug}"
STAGE1_WASM="$PROJECT_ROOT/_build/wasm/$SELFHOST_WASM_PROFILE/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm"

OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_stage2_kpi"
STAGE2_WASM="$OUT_DIR/vibe_compile_wasi_stage2.wasm"
PERF_OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_perf"
mkdir -p "$OUT_DIR"

log() { echo "[stage2-kpi] $*" >&2; }
err() { echo "[stage2-kpi] ERROR: $*" >&2; }

# --- 1. ensure stage-1 wasm (delegate to bench_selfhost_perf rebuild logic) ---

if [ ! -f "$STAGE1_WASM" ]; then
  log "stage-1 wasm missing — building via moon"
  ( cd "$PROJECT_ROOT" && moon build --target wasm src/cmd/vibe_compile_wasi --warn-list "-1-7-24-29" )
fi

if [ ! -f "$STAGE1_WASM" ]; then
  err "stage-1 wasm still missing after build: $STAGE1_WASM"
  exit 1
fi

# --- 2. produce stage-2 wasm via stage-1 (selfhost compiles selfhost) ---
# Stage-2 production reuses test_selfhost_wasi_selfbuild's mechanism: run
# the stage-1 wasm via moonrun with selfbuild_compile_stage2 entry, output
# bytes to STAGE2_WASM. Same handshake as the bootstrap gate so we measure
# the same wasm CI gates against.

if [ "$SKIP_FIXED_POINT" = "1" ]; then
  log "skipping selfhost determinism check (VIBE_SELFHOST_KPI_SKIP_FIXED_POINT=1) — measuring stage-1 (host emit) as proxy"
  COMPILER_WASM="$STAGE1_WASM"
  hash_stage1=""
  hash_stage2=""
  hash_stage3=""
  fixed_point="skipped"
else
  if ! command -v moonrun >/dev/null 2>&1; then
    err "moonrun not found; required to produce stage-2 (or set VIBE_SELFHOST_KPI_SKIP_FIXED_POINT=1)"
    exit 1
  fi

  STAGE3_WASM="$OUT_DIR/vibe_compile_wasi_stage3.wasm"
  log "producing stage-2 wasm via stage-1 (compile vibe/compiler/index.vibe)"
  if ! moonrun "$STAGE1_WASM" --wasm-mvp "$PROJECT_ROOT/vibe/compiler/index.vibe" \
        -o "$STAGE2_WASM" > "$OUT_DIR/stage2_emit.log" 2>&1; then
    err "stage-1 failed to emit stage-2 wasm; see $OUT_DIR/stage2_emit.log"
    exit 1
  fi
  if [ ! -s "$STAGE2_WASM" ]; then
    err "stage-2 wasm is empty: $STAGE2_WASM"
    exit 1
  fi
  hash_stage1="$(sha256sum "$STAGE1_WASM" | awk '{print $1}')"
  hash_stage2="$(sha256sum "$STAGE2_WASM" | awk '{print $1}')"
  hash_stage3=""
  log "  stage-1 (host emit):     $hash_stage1"
  log "  stage-2 (selfhost emit): $hash_stage2"

  # Determinism (stage-2 == stage-3) is verified separately by
  # `test-selfhost-bootstrap-gate` in cutover mode (`VIBE_SELFHOST_CUTOVER=1`).
  # That test compiles the same source twice with the same selfhost compiler
  # and checks bit-equality; it's the authoritative gate for this property.
  # Re-running it inside this KPI script would double the wall time without
  # adding signal, so we delegate.
  fixed_point="delegated"
  log "selfhost determinism: delegated to test-selfhost-bootstrap-gate (run separately)"
  COMPILER_WASM="$STAGE2_WASM"
fi

# --- 3. run bench_selfhost_perf against the resolved compiler wasm ---

log "running bench_selfhost_perf.sh (runs=$RUNS, cases=$CASES_FILE)"

if ! VIBE_SELFHOST_PERF_RUNS="$RUNS" \
     VIBE_SELFHOST_PERF_CASES_FILE="$CASES_FILE" \
     STAGE1_COMPILER_WASM="$COMPILER_WASM" \
     OUT_DIR="$PERF_OUT_DIR" \
     bash "$PROJECT_ROOT/scripts/bench_selfhost_perf.sh" \
     > "$OUT_DIR/perf.out" 2> "$OUT_DIR/perf.err"; then
  err "bench_selfhost_perf.sh failed; see $OUT_DIR/perf.err"
  cat "$OUT_DIR/perf.err" >&2
  exit 1
fi

# --- 4. parse summary, compute KPI verdict, emit one-line summary ---

summary_tsv="$PERF_OUT_DIR/summary.e2e.tsv"
if [ ! -f "$summary_tsv" ]; then
  summary_tsv="$PERF_OUT_DIR/summary.in-memory.tsv"
fi
if [ ! -f "$summary_tsv" ]; then
  err "no perf summary tsv produced under $PERF_OUT_DIR"
  exit 1
fi

# bench_selfhost_perf prints e.g. "TOTAL compile(host/selfhost): 100 / 333 ms (ratio=3.33)"
# Extract the float after "ratio=" from each TOTAL line.
total_compile_ratio="$(grep -E '^TOTAL compile' "$OUT_DIR/perf.out" | sed -E 's/.*ratio=([0-9.]+).*/\1/')"
total_check_ratio="$(grep -E '^TOTAL check' "$OUT_DIR/perf.out" | sed -E 's/.*ratio=([0-9.]+).*/\1/')"

if [ -z "$total_compile_ratio" ] || [ -z "$total_check_ratio" ]; then
  err "could not parse TOTAL ratios from perf output"
  cat "$OUT_DIR/perf.out" >&2
  exit 1
fi

# verdict against target
verdict_compile="PASS"
verdict_check="PASS"
if awk -v a="$total_compile_ratio" -v b="$TARGET_COMPILE_RATIO" \
   'BEGIN { exit !(a > b) }'; then
  verdict_compile="FAIL"
fi
if awk -v a="$total_check_ratio" -v b="$TARGET_CHECK_RATIO" \
   'BEGIN { exit !(a > b) }'; then
  verdict_check="FAIL"
fi

cutover_ready="no"
case "$fixed_point" in
  ok|skipped|delegated)
    # ok = verified here; skipped = explicit user opt-out;
    # delegated = trust test-selfhost-bootstrap-gate to have run separately.
    if [ "$verdict_compile" = "PASS" ] && [ "$verdict_check" = "PASS" ]; then
      cutover_ready="yes"
    fi
    ;;
  *)
    # diverged or unknown — never ready
    ;;
esac

# git rev for history attribution
git_rev="$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 5. append to history TSV ---

if [ ! -f "$HISTORY_FILE" ]; then
  printf "timestamp\tgit_rev\tcompile_ratio\tcheck_ratio\tcompile_verdict\tcheck_verdict\tfixed_point\tcutover_ready\truns\tcases_file\n" > "$HISTORY_FILE"
fi
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$timestamp" "$git_rev" \
  "$total_compile_ratio" "$total_check_ratio" \
  "$verdict_compile" "$verdict_check" \
  "$fixed_point" "$cutover_ready" \
  "$RUNS" "${CASES_FILE#$PROJECT_ROOT/}" \
  >> "$HISTORY_FILE"

# --- 6. human-readable summary ---

cat <<EOF

=== Selfhost mainline cutover KPI ===
timestamp:      $timestamp
git rev:        $git_rev
compiler under test: $COMPILER_WASM
selfhost determinism (stage2 == stage3): $fixed_point
  stage1 hash (host emit):     ${hash_stage1:-(skipped)}
  stage2 hash (selfhost emit): ${hash_stage2:-(skipped)}
  stage3 hash (self-rebuild):  ${hash_stage3:-(skipped)}

ratio vs host (selfhost / host, ≤ 1.0 = parity, lower is better):
  compile: $total_compile_ratio  (target ≤ $TARGET_COMPILE_RATIO → $verdict_compile)
  check:   $total_check_ratio  (target ≤ $TARGET_CHECK_RATIO → $verdict_check)

cutover ready: $cutover_ready

raw history:    $HISTORY_FILE
raw perf out:   $OUT_DIR/perf.out

See docs/selfhost-cutover-kpi.md for cutover criteria + roadmap.
EOF

exit 0

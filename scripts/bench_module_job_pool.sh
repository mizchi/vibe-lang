#!/usr/bin/env bash
# Module-job process pool: determinism gate + parallel-speedup measurement
# (#1239 step 4(D)).
#
# WHY THIS EXISTS
#
# #1239 states that real wall-clock speedup "requires a host that drives
# several wasm instances", and that the Wasmtime multi-instance host that
# would provide it does not exist yet. The stated reason is that such a host
# "shares one Engine and compiled Module".
#
# Measurement says that sharing is already paid for. `viberun --precompile`
# produces an AOT `.cwasm`, and the production launcher (runtime/vibe) already
# selects it with staleness guards. Per module job, in a FRESH PROCESS:
#
#     compiler as .wasm    ~485ms   (Cranelift JIT on every start)
#     compiler as .cwasm     ~8ms   (AOT image deserialize)
#
# 8ms of process startup amortizes away against real job work, so an ordinary
# PROCESS pool over the existing `.cwasm` already scales -- no Wasmtime
# thread pool, no shared mutable state, and stricter isolation than threads
# (which is what the shared-nothing contract wants anyway).
#
# This script pins both halves of that claim:
#
#   determinism (hard gate)  outcome, fingerprint, and env bytes must be
#                            IDENTICAL at -P 1/2/4/8. This is #1239's own
#                            acceptance criterion; without it a speedup
#                            number means nothing.
#   speedup (measured)       reported always; asserted only on >= 4 cores,
#                            with a deliberately loose floor, since absolute
#                            timings are machine- and load-dependent.
#
# Jobs are built from real compiler sources, and only sources that check
# clean in a bare job dir are kept -- a module whose imports need dependency
# environments threaded through would diagnose here, which is correct but
# does less work and would skew the timing.
#
# Env:
#   VIBE_JOBPOOL_BENCH_COMPILER   compiler wasm/cwasm override
#   VIBE_JOBPOOL_BENCH_RUNNER     viberun binary override
#   VIBE_JOBPOOL_BENCH_JOBS       target job count (default 32)
#   VIBE_P3_GATE_REQUIRE_TOOLS=1  missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/module_job_pool}"
TARGET_JOBS="${VIBE_JOBPOOL_BENCH_JOBS:-32}"

require_or_skip() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "module-job pool gate FAILED: $1 (required mode)" >&2
    exit 1
  fi
  echo "module-job pool gate skipped: $1"
  exit 0
}

RUNNER="${VIBE_JOBPOOL_BENCH_RUNNER:-$PROJECT_ROOT/runtime/viberun/target/release/viberun}"
if [ ! -x "$RUNNER" ]; then
  command -v cargo >/dev/null 2>&1 || require_or_skip "viberun not built and cargo not installed"
  echo "[jobpool] building viberun..."
  (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1) \
    || require_or_skip "failed to build runtime/viberun"
fi

COMPILER="${VIBE_JOBPOOL_BENCH_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
[ -f "$COMPILER" ] || require_or_skip "no compiler wasm found"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/jobs"

# AOT-precompile once. This is the step that makes a process pool viable, so
# the benchmark measures the configuration the production launcher actually
# uses rather than the JIT-every-start one.
CWASM="$OUT_DIR/compiler.cwasm"
case "$COMPILER" in
  *.cwasm) CWASM="$COMPILER" ;;
  *) "$RUNNER" --precompile "$COMPILER" -o "$CWASM" >/dev/null 2>&1 \
       || require_or_skip "viberun --precompile failed" ;;
esac
echo "[jobpool] compiler: $COMPILER"
echo "[jobpool] aot image: $CWASM ($(wc -c <"$CWASM") bytes)"

run_job() {  # run_job <jobdir>
  VIBE_MODULE_JOB_DIR=1 "$RUNNER" "$CWASM" "$1" "$1/worker.out" __no_entry__ >/dev/null 2>&1 || true
}

# --- build candidate jobs from real compiler sources -------------------------
seed=0
for f in $(find lib/@vibe/compiler -name '*.vibe' -size +8k -size -60k | sort | head -40); do
  d="$OUT_DIR/jobs/seed$seed"
  mkdir -p "$d"
  cp "$f" "$d/source.vibe"
  printf 'version\t1\npath\t/virtual/pkg/m%s.vibe\n' "$seed" >"$d/job.txt"
  run_job "$d"
  # Keep only sources that check clean standalone (see header).
  [ "$(cat "$d/outcome.txt" 2>/dev/null)" = "ok" ] || rm -rf "$d"
  seed=$((seed + 1))
done
CLEAN=$(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$CLEAN" -gt 0 ] || require_or_skip "no compiler source checked clean standalone"

# Replicate up to the target count so the measurement is not dominated by
# per-process constant cost at small N.
i=0
while [ "$(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -lt "$TARGET_JOBS" ]; do
  for d in $(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d -name 'seed*' | sort); do
    cp -r "$d" "$OUT_DIR/jobs/copy${i}_$(basename "$d")"
    i=$((i + 1))
    [ "$(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -lt "$TARGET_JOBS" ] || break
  done
done
JOBS=$(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)
echo "[jobpool] jobs: $JOBS ($CLEAN distinct sources, replicated)"

reset_jobs() { rm -f "$OUT_DIR"/jobs/*/outcome.txt "$OUT_DIR"/jobs/*/env.out \
                     "$OUT_DIR"/jobs/*/diag.txt "$OUT_DIR"/jobs/*/fingerprint.out; }

# outcome + fingerprint + env hash for every job, in a stable order.
snapshot() {
  for d in $(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | sort); do
    printf '%s\t%s\t%s\t%s\n' "$(basename "$d")" \
      "$(cat "$d/outcome.txt" 2>/dev/null || echo MISSING)" \
      "$(cat "$d/fingerprint.out" 2>/dev/null || echo MISSING)" \
      "$(sha256sum <"$d/env.out" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"
  done
}

measure() {  # measure <parallelism> -> prints elapsed ms, writes $OUT_DIR/snap.<P>
  local p="$1" start_ns
  reset_jobs
  start_ns=$(date +%s%N)
  if [ "$p" = "1" ]; then
    for d in $(find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | sort); do run_job "$d"; done
  else
    find "$OUT_DIR/jobs" -mindepth 1 -maxdepth 1 -type d | sort \
      | xargs -P "$p" -I{} env VIBE_MODULE_JOB_DIR=1 "$RUNNER" "$CWASM" {} {}/worker.out __no_entry__ \
        >/dev/null 2>&1
  fi
  local elapsed=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  snapshot >"$OUT_DIR/snap.$p"
  echo "$elapsed"
}

NPROC="$(nproc 2>/dev/null || echo 1)"
echo "[jobpool] nproc: $NPROC"

SEQ_MS=$(measure 1)
echo "[jobpool] -P 1 (sequential): ${SEQ_MS}ms"

FAILED=0
for P in 2 4 8; do
  MS=$(measure "$P")
  if ! diff -q "$OUT_DIR/snap.1" "$OUT_DIR/snap.$P" >/dev/null; then
    echo "module-job pool gate FAILED: -P $P produced different results than sequential -- outcome/fingerprint/env must not depend on scheduling" >&2
    diff "$OUT_DIR/snap.1" "$OUT_DIR/snap.$P" | head -10 >&2
    FAILED=1
    continue
  fi
  if [ "$MS" -gt 0 ]; then
    SPEEDUP=$(awk -v s="$SEQ_MS" -v m="$MS" 'BEGIN{printf "%.2f", s/m}')
  else
    SPEEDUP="n/a"
  fi
  echo "[jobpool] -P $P: ${MS}ms (speedup ${SPEEDUP}x, identical results)"
  eval "MS_$P=$MS"
done
[ "$FAILED" = "0" ] || exit 1

# Speedup assertion only where there are cores to use, with a loose floor:
# the point is "a process pool scales", not a specific number on a specific
# machine. A shared CI runner can be arbitrarily contended.
if [ "$NPROC" -ge 4 ]; then
  FLOOR_NUM=$(( SEQ_MS * 10 / 15 ))   # require at least 1.5x at -P 4
  if [ "${MS_4:-$SEQ_MS}" -gt "$FLOOR_NUM" ]; then
    echo "module-job pool gate FAILED: -P 4 took ${MS_4}ms vs ${SEQ_MS}ms sequential on ${NPROC} cores -- expected at least 1.5x, so the jobs are not actually running in parallel" >&2
    exit 1
  fi
else
  echo "[jobpool] speedup assertion skipped (nproc=$NPROC < 4); determinism was still enforced"
fi

echo "module-job pool gate passed"

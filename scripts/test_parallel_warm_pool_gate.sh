#!/usr/bin/env bash
# Warm-pool coordinator gate (#1239 step 4(D)).
#
# The coordinator (scripts/parallel_warm_pool.sh) dispatches module jobs a
# whole plan_module_order rank at a time. This pins the property that makes
# such a schedule safe to turn on, which is #1239's own acceptance criterion:
#
#   what it publishes must not depend on how much of it ran at once.
#
# Asserted on BYTES, not just key names. A coordinator that raced could
# plausibly publish the same set of fingerprints with one module's env built
# from a half-written dependency -- identical key list, different content --
# so comparing the manifest alone would miss exactly the bug this exists for.
#
#
# Env:
#   VIBE_WARM_POOL_GATE_COMPILER  compiler wasm/cwasm override
#   VIBE_WARM_POOL_GATE_RUNNER    runner override
#   VIBE_P3_GATE_REQUIRE_TOOLS=1  missing tools = FAIL instead of skip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/test/warm_pool_gate}"
SAMPLE="$PROJECT_ROOT/scripts/fixtures/parallel_project_sample"

require_or_skip() {
  if [ "${VIBE_P3_GATE_REQUIRE_TOOLS:-0}" = "1" ]; then
    echo "warm-pool gate FAILED: $1 (required mode)" >&2
    exit 1
  fi
  echo "warm-pool gate skipped: $1"
  exit 0
}

RUNNER="${VIBE_WARM_POOL_GATE_RUNNER:-$PROJECT_ROOT/runtime/viberun/target/release/viberun}"
if [ ! -x "$RUNNER" ]; then
  command -v cargo >/dev/null 2>&1 || require_or_skip "viberun not built and cargo not installed"
  echo "[warm-pool-gate] building viberun..."
  (cd "$PROJECT_ROOT/runtime/viberun" && cargo build --release >/dev/null 2>&1) \
    || require_or_skip "failed to build runtime/viberun"
fi

COMPILER="${VIBE_WARM_POOL_GATE_COMPILER:-}"
if [ -z "$COMPILER" ]; then
  # `|| true`: no generations dir => ls exits nonzero => pipefail would abort
  # before the seed fallback below could run.
  COMPILER="$(ls -td "$PROJECT_ROOT"/_build/selfhost/generations/*/ 2>/dev/null | head -1 || true)stage2.wasm"
  [ -f "$COMPILER" ] || COMPILER="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
fi
[ -f "$COMPILER" ] || require_or_skip "no compiler wasm found"
COMPILER="$(cd "$(dirname "$COMPILER")" && pwd)/$(basename "$COMPILER")"
[ -d "$SAMPLE" ] || require_or_skip "sample project missing: $SAMPLE"

echo "[warm-pool-gate] compiler: $COMPILER"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

fail=0
die() { echo "warm-pool gate FAILED: $*" >&2; fail=1; }

# The plan mode this section used to exercise -- an ordering-only
# `VIBE_PLAN_MODULE_ORDER` CLI mode taking resolved edges as TSV -- is gone
# (#1259). VIBE_MODULE_PLAN, which the coordinator actually calls, does the
# discovery AND the ranking in one call, and the ordering rule itself is
# pinned in-process by lib/@vibe/graph/module_order_test.vibe (diamond, ties
# sharing a rank, cycle rejection, visit-order invariance). What is left here
# is the property only an out-of-process coordinator can violate.

# --- 2. the coordinator: identical published bytes at every parallelism ------
snapshot_cache() {  # snapshot_cache <cachedir> -> "<relpath> <sha256>" per line
  ( cd "$1" && find . -type f | sort | while IFS= read -r f; do
      printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)"
    done )
}

BASE=""
for P in 1 2 4 8; do
  CACHE="$OUT_DIR/cache.$P"
  rm -rf "$CACHE"; mkdir -p "$CACHE"
  if ! ( cd "$SAMPLE" && VIBE_BUILD_CACHE_DIR="$CACHE" timeout 900 \
           bash "$PROJECT_ROOT/scripts/parallel_warm_pool.sh" "$COMPILER" main.vibe "$P" "$RUNNER" \
           > "$OUT_DIR/warm.$P.log" 2>&1 ); then
    die "coordinator exited nonzero at -P $P: $(tail -1 "$OUT_DIR/warm.$P.log")"
    continue
  fi
  snapshot_cache "$CACHE" > "$OUT_DIR/snap.$P"
  ENTRIES="$(wc -l < "$OUT_DIR/snap.$P" | tr -d ' ')"
  # A run that published nothing would compare equal to every other empty run,
  # so the whole determinism assertion below would pass vacuously.
  if [ "$ENTRIES" -eq 0 ]; then
    die "-P $P published no cache entries at all -- the comparison below would be vacuous"
    continue
  fi
  if [ -z "$BASE" ]; then
    BASE="$P"
    echo "[warm-pool-gate] -P $P: $ENTRIES cache entries ($(tail -1 "$OUT_DIR/warm.$P.log"))"
  elif diff -q "$OUT_DIR/snap.$BASE" "$OUT_DIR/snap.$P" >/dev/null; then
    echo "[warm-pool-gate] -P $P: $ENTRIES entries, byte-identical to -P $BASE"
  else
    die "-P $P published different bytes than -P $BASE -- what the warm publishes depends on scheduling"
    diff "$OUT_DIR/snap.$BASE" "$OUT_DIR/snap.$P" | head -10 >&2
  fi
done

# --- 3. bounded parallelism, joined ranks, no leaked workers (#1259) ---------
#
# #1239 listed "bounded parallelism and backpressure" and "no task leak" as
# acceptance criteria and nothing checked either one. `xargs -P N` is the
# bound and the backpressure both -- it does not read the next path until a
# slot frees, and it reaps every child before the rank returns -- but that was
# an argument, not a measurement.
#
# VIBE_WARM_POOL_TRACE makes each job append "+" on entry and "-" on exit, so
# the running sum is the number of workers in flight and its maximum is the
# real peak. The sample project cannot show this: main -> mid -> leaf puts one
# module in every rank, so ANY bound holds trivially. This fixture is a
# fan-out instead -- eight independent leaves under one root -- so rank 0 has
# eight dispatchable modules and a broken bound would show up immediately.
echo "[warm-pool-gate] measuring peak parallelism on a fan-out graph"
WIDE="$OUT_DIR/wide"
rm -rf "$WIDE"; mkdir -p "$WIDE"
wide_imports=""
wide_sum="0"
for n in 1 2 3 4 5 6 7 8; do
  printf 'export let v%s = () -> Int { %s }\n' "$n" "$n" > "$WIDE/leaf$n.vibe"
  wide_imports="$wide_imports$(printf 'import ./leaf%s.vibe { v%s }\n' "$n" "$n")"
  wide_sum="$wide_sum + v$n()"
done
{ printf '%s\n' "$wide_imports"; printf 'export let _start = () -> Int { %s }\n' "$wide_sum"; } > "$WIDE/root.vibe"

peak_at() {  # peak_at <jobs> -> echoes the max concurrent worker count
  # Separate `local` statements on purpose: bash expands every word of a
  # `local` before assigning any of them, so `local p="$1" trace="...$p"`
  # would expand $p while it is still unset -- fatal under `set -u`.
  local p="$1"
  local trace="$OUT_DIR/trace.$p" cache="$OUT_DIR/wcache.$p"
  rm -rf "$cache"; mkdir -p "$cache"
  : > "$trace"
  ( cd "$WIDE" && VIBE_BUILD_CACHE_DIR="$cache" VIBE_WARM_POOL_TRACE="$trace" timeout 900 \
      bash "$PROJECT_ROOT/scripts/parallel_warm_pool.sh" "$COMPILER" root.vibe "$p" "$RUNNER" \
      > "$OUT_DIR/wide.$p.log" 2>&1 ) || return 1
  awk '{ if ($0 == "+") { c++; if (c > m) m = c } else if ($0 == "-") c-- }
       END { print m + 0 }' "$trace"
}

PEAK1="$(peak_at 1 || echo ERR)"
PEAK4="$(peak_at 4 || echo ERR)"
if [ "$PEAK1" = "ERR" ] || [ "$PEAK4" = "ERR" ]; then
  die "the fan-out coordinator run failed (see $OUT_DIR/wide.*.log)"
else
  # -P 1 must be exactly 1: this is the vacuity guard. Without it "peak <= N"
  # would also pass if the trace were empty or the pool silently serial.
  [ "$PEAK1" = "1" ] || die "-P 1 peaked at $PEAK1 concurrent workers (want exactly 1) -- the trace or the bound is wrong"
  [ "$PEAK4" -le 4 ] || die "-P 4 peaked at $PEAK4 concurrent workers, above its own bound of 4"
  # And it must actually overlap, or "<= 4" is the trivial truth again.
  [ "$PEAK4" -ge 2 ] || die "-P 4 never ran two workers at once (peak $PEAK4) on an 8-wide rank -- the pool is serial in practice"
  echo "[warm-pool-gate] peak workers: -P 1 -> $PEAK1, -P 4 -> $PEAK4 (bound holds, and 4 really overlaps)"
fi

# No leak: xargs reaps each rank's children before the next rank starts, and
# the run is fully joined by the time the script returns. Nothing of the
# runner may outlive it.
# `|| true` on the pgrep, not just 2>/dev/null: pgrep exits 1 when nothing
# matches, which under `set -o pipefail` would abort the script on exactly the
# outcome this is checking for.
LEAKED="$( { pgrep -f "$RUNNER" 2>/dev/null || true; } | wc -l | tr -d ' ')"
if [ "$LEAKED" != "0" ]; then
  die "$LEAKED runner process(es) outlived the coordinator -- workers are leaking"
else
  echo "[warm-pool-gate] no runner process outlived the coordinator"
fi

[ "$fail" = "0" ] || exit 1
echo "warm-pool gate passed"

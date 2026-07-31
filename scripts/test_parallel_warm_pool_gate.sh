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
# Also asserted: the plan mode itself (ranks, cycle rejection), since the
# coordinator's correctness rests on it and a wrong rank shows up here as a
# schedule that happens to work on a small graph rather than as a failure.
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

# --- 1. the plan mode: ranks, tie-breaking, cycle rejection ------------------
#
# A diamond is the discriminating shape: root depends on a and b, both of
# which depend on c. Nothing may schedule c after a or b, and a/b must land
# in the SAME rank -- a plan that serialized them would still "work" but
# would give the coordinator no parallelism at all, silently.
# Sets PLAN and PLAN_DIAG. Deliberately NOT a function that echoes its result:
# `X="$(plan_of ...)"` runs the body in a subshell, so any variable it set
# there would be lost -- both outputs travel through files instead.
run_plan() {  # run_plan <edges-file>
  local edges="$1" out="$OUT_DIR/plan.out"
  rm -f "$out" "$out.diag"
  env VIBE_PLAN_MODULE_ORDER=1 timeout 300 "$RUNNER" "$COMPILER" "$edges" "$out" __no_entry__ \
    >/dev/null 2>&1 || true
  PLAN="$(cat "$out" 2>/dev/null || true)"
  PLAN_DIAG="$(cat "$out.diag" 2>/dev/null || true)"
}
PLAN=""
PLAN_DIAG=""

printf 'root.vibe\ta.vibe\tb.vibe\na.vibe\tc.vibe\nb.vibe\tc.vibe\nc.vibe\n' > "$OUT_DIR/diamond.tsv"
run_plan "$OUT_DIR/diamond.tsv"
DIAMOND="$PLAN"
EXPECTED="$(printf '0\tc.vibe\n1\ta.vibe\n1\tb.vibe\n2\troot.vibe')"
if [ "$DIAMOND" != "$EXPECTED" ]; then
  die "diamond plan is not the canonical order (rank asc, then path asc)"
  printf 'expected:\n%s\ngot:\n%s\n' "$EXPECTED" "$DIAMOND" >&2
else
  echo "[warm-pool-gate] diamond plan ok (c=0, {a,b}=1 share a rank, root=2)"
fi

printf 'x.vibe\ty.vibe\ny.vibe\tx.vibe\n' > "$OUT_DIR/cycle.tsv"
run_plan "$OUT_DIR/cycle.tsv"
CYC="$PLAN"
# The wording must match ensure_fingerprint_fs_go's inline check: moving the
# rejection upfront must not change what a user sees.
case "$PLAN_DIAG" in
  *"import cycle detected"*) echo "[warm-pool-gate] cycle rejected: $PLAN_DIAG" ;;
  *) die "a cyclic graph produced no cycle diagnostic (plan=[$CYC] diag=[$PLAN_DIAG])" ;;
esac
[ -z "$CYC" ] || die "a cyclic graph still produced a plan: [$CYC]"

: > "$OUT_DIR/empty.tsv"
run_plan "$OUT_DIR/empty.tsv"
EMPTY="$PLAN"
if [ -n "$EMPTY" ] || [ -n "$PLAN_DIAG" ]; then
  die "empty graph should yield an empty plan and no diagnostic (plan=[$EMPTY] diag=[$PLAN_DIAG])"
else
  echo "[warm-pool-gate] empty graph ok (empty plan, no diagnostic)"
fi

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

[ "$fail" = "0" ] || exit 1
echo "warm-pool gate passed"

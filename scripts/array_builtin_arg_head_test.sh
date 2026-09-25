#!/usr/bin/env bash
# The `Array::` builtins check their receiver AND their callback (#2936).
#
# Two holes, one issue:
#
#   Array::map(0, 0)    -- an Int where the ARRAY goes
#   Array::map(xs, 0)   -- an Int where the FUNCTION goes
#
# both passed `vibe check` clean on a stage2 from `c4d075f9c` and then emitted
# a module that would not load: `viberun: from_file: failed to compile:
# wasm[0]::function[13]::main`, with no source location. The second is the one
# a person writes -- forgetting the closure.
#
# The receiver hole was structural. The check lives in the GENERAL
# builtin-call arm, and six names have a dedicated arm ahead of it:
# push, reverse, concat, slice, fold, map. Names without an arm (length, any,
# set) fell through and were checked all along, which is why the family looked
# inconsistent rather than broken.
#
# The callback hole was a deliberate omission with a stale reason: the
# non-receiver head table excluded higher-order arguments because they "need
# real signature inference, not a head". True for checking the callback's
# parameter types; beside the point for rejecting a bare Int.
#
# So the rows below are three groups, and the last two are what keep the fix
# honest rather than merely strict:
#
#   1. RED      every Array builtin refuses an Int receiver
#   2. RED      every higher-order Array builtin refuses a non-function callback
#   3. CONTROL  length / any / set still refuse (they were never broken -- a
#               fix that moved the check could silently lose them)
#   4. CONTROL  real higher-order code still compiles AND RUNS with the right
#               answers, including a named function passed as a value. Without
#               this, "refuse every callback" would pass groups 1-2.
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and says which.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 array-arg-head "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "array-arg-head: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] || { echo "array-arg-head: no runner at $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-array-arg-head.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

# check_refused <expr> <what must appear in the diagnostic>
check_refused() {
  printf 'fn main allows Console {\n  let xs = [1, 2]\n  let _ = %s\n  println("ok")\n}\n' "$1" > "$WORK/p.vibex"
  local out
  out="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 400 \
    bash runtime/vibe check "$WORK/p.vibex" 2>&1)"
  if [ -z "$out" ]; then
    note "  FAIL $1: vibe check is CLEAN -- this compiles to an unloadable module"
    fail=1
  elif ! printf '%s' "$out" | grep -qF "$2"; then
    note "  FAIL $1: refused, but not for the expected reason"
    printf '%s\n' "$out" | head -1 | sed 's/^/        /'
    fail=1
  else
    note "  ok   $1"
  fi
}

note "=== 1. RED: an Int where the array goes ==="
for e in 'Array::push(0, 0)' 'Array::reverse(0)' 'Array::concat(0, 0)' \
         'Array::slice(0, 0, 0)' 'Array::fold(0, 0, 0)' 'Array::map(0, 0)'; do
  check_refused "$e" "receiver type Int"
done

note "=== 2. RED: an Int where the callback goes (the case people write) ==="
for e in 'Array::map(xs, 0)' 'Array::filter(xs, 0)' 'Array::any(xs, 0)' \
         'Array::all(xs, 0)' 'Array::find(xs, 0)'; do
  check_refused "$e" "(arg 1): Int"
done
check_refused 'Array::fold(xs, 0, 0)' "(arg 2): Int"

note "=== 3. CONTROL: the names that were never broken still refuse ==="
# A fix that relocated the check rather than sharing it could lose these
# without any of the rows above noticing.
for e in 'Array::length(0)' 'Array::any(0, 0)' 'Array::set(0, 0, 0)'; do
  check_refused "$e" "receiver type Int"
done

note "=== 4. CONTROL: real higher-order code still compiles and runs ==="
# The one that stops "refuse every callback" from passing groups 1 and 2.
cat > "$WORK/pos.vibex" <<'V'
fn add1(x: Int) -> Int {
  x + 1
}

fn main allows Console {
  let xs = [1, 2, 3]
  let m = Array::map(xs, (x) -> { x * 2 })
  let f = Array::filter(xs, (x) -> { x > 1 })
  let a = Array::any(xs, (x) -> { x > 2 })
  let l = Array::all(xs, (x) -> { x > 0 })
  let d = Array::fold(xs, 0, (acc, x) -> { acc + x })
  let n = Array::map(xs, add1)
  println("map=\{Array::get(m, 0)} filter=\{Array::length(f)} any=\{a} all=\{l} fold=\{d} named=\{Array::get(n, 2)}")
}
V
chk="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 400 bash runtime/vibe check "$WORK/pos.vibex" 2>&1)"
if [ -n "$chk" ]; then
  note "  FAIL valid higher-order code no longer type-checks:"
  printf '%s\n' "$chk" | head -2 | sed 's/^/        /'
  fail=1
else
  note "  ok   vibe check is clean"
fi
got="$(VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 500 bash runtime/vibe run "$WORK/pos.vibex" 2>&1 | tail -1)"
want="map=2 filter=2 any=true all=true fold=6 named=4"
if [ "$got" = "$want" ]; then
  note "  ok   and answers: $got"
else
  note "  FAIL wrong answer"
  note "        want: $want"
  note "        got:  $got"
  fail=1
fi

note
if [ "$fail" = 0 ]; then note "[array-arg-head] ok"; else note "[array-arg-head] FAIL"; fi
exit "$fail"

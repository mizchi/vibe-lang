#!/usr/bin/env bash
# `vibe mutate` end to end: the launcher, `viberun --test-each`, the source
# overlay and `vibe mutate-report` together, on a fixture whose answers are
# worked out by hand below.
#
# Target (lib.vibe) and its sites:
#   is_adult: age >= 18   -> boundary `>`, negate `<`, const 18 -> 19
#   double:   n * 2       -> arith `/`, const 2 -> 3
#   greet:    "hi " + s   -> arith `-`            (a String `-`: unviable)
#   inc:      n + 1       -> arith `-`, const 1 -> 0   (no test calls inc)
# Tests (lib_test.vibe):
#   "adult at 18"  kills boundary, negate, const 19
#   "adult at 30"  kills negate only        -> subsumed by "adult at 18"
#   "minor at 5"   kills negate only        -> subsumed by "adult at 18"
#   "double"       kills both double sites
#   "greet"        its only site is unviable -> kills nothing
# So 8 sites: 5 killed, 2 survived (inc), 1 unviable; the cover keeps 2 tests.
#
# The rows that keep this honest:
#   - the target's bytes are identical after the run (no mutant is ever
#     written to it; the overlay answers its reads);
#   - exit 1 with survivors, and exit 0 once a test for `inc` is added -- so
#     the verdict can change, rather than merely being printed.
#
#   VIBE_CLI_WASM  the compiler to ask. Unset, scripts/resolve_stage2.sh picks
#                  HEAD's generation and says which.
#   VIBE_RUNNER    the Rust runner. Unset, scripts/ensure_viberun.sh builds it.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
CLI="$(resolve_stage2 vibe-mutate "${VIBE_CLI_WASM:-}")" || exit 1
[ -n "$CLI" ] && [ -f "$CLI" ] || {
  echo "vibe-mutate: no compiler to ask; set VIBE_CLI_WASM" >&2; exit 2; }
if [ -z "${VIBE_RUNNER:-}" ]; then
  bash scripts/ensure_viberun.sh >&2 || { echo "vibe-mutate: could not build runtime/viberun" >&2; exit 2; }
fi
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] || { echo "vibe-mutate: no runner at $RUNNER" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-mutate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/lib.vibe" <<'EOF'
export fn is_adult(age: Int) -> Bool {
  age >= 18
}

export fn double(n: Int) -> Int {
  n * 2
}

export fn greet(s: String) -> String {
  "hi " + s
}

export fn inc(n: Int) -> Int {
  n + 1
}
EOF
cat > "$WORK/lib_test.vibe" <<'EOF'
import ./lib.vibe {
  double, greet, is_adult
}

test "adult at 18" {
  assert(is_adult(18))
}

test "adult at 30" {
  assert(is_adult(30))
}

test "minor at 5" {
  assert(!is_adult(5))
}

test "double" {
  assert(double(3) == 6)
}

test "greet" {
  assert(greet("x") == "hi x")
}
EOF

fail=0
note() { printf '%s\n' "$*"; }
expect_line() {
  if printf '%s\n' "$out" | grep -qxF "$1"; then
    note "  ok   $1"
  else
    note "  FAIL missing: $1"
    fail=1
  fi
}

before="$(cksum < "$WORK/lib.vibe")"
out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe lib_test.vibe 2>"$WORK/err")"
status=$?

note "=== the report ==="
[ "$status" = 1 ] && note "  ok   exit 1 with survivors" || { note "  FAIL exit $status, expected 1"; fail=1; }
expect_line "mutants: 8 sites, 5 killed, 2 survived, 1 unviable, 0 identical-binary"
expect_line "score: 5/7 killed (71.4%)"
expect_line 'SURVIVED lib.vibe:14:5 arith `+` -> `-` | n + 1'
expect_line 'SURVIVED lib.vibe:14:7 const `1` -> `0` | n + 1'
expect_line 'TEST kills=3 unique=2 lib_test.vibe "adult at 18"'
expect_line 'REDUNDANT kills=1 lib_test.vibe "adult at 30" subsumed-by lib_test.vibe "adult at 18"'
expect_line 'REDUNDANT kills=1 lib_test.vibe "minor at 5" subsumed-by lib_test.vibe "adult at 18"'
expect_line 'NOKILL lib_test.vibe "greet"'
expect_line "minimal: 2 of 5 tests kill every killed mutant"

note "=== the tree is untouched ==="
if [ "$(cksum < "$WORK/lib.vibe")" = "$before" ]; then
  note "  ok   lib.vibe has its original bytes"
else
  note "  FAIL lib.vibe was modified by the run"; fail=1
fi
if find "$WORK" -name 'mutant_*.vibe' | grep -q .; then
  note "  FAIL a mutant file was left behind"; fail=1
else
  note "  ok   no mutant file left behind"
fi

# Mutant binaries go to the run's own build dir: a concurrent `vibe test`
# reads .vibe/build/test, and must never find a mutant there.
if [ -e "$WORK/.vibe/build/test" ]; then
  note "  FAIL the run wrote into .vibe/build/test, where vibe test reads"; fail=1
else
  note "  ok   nothing written where vibe test reads"
fi
if [ -s "$WORK/.vibe/build/mutate/results.tsv" ] && ! find "$WORK/.vibe/build/mutate" -name 'run.*' | grep -q .; then
  note "  ok   the kill matrix is kept, the run directory is not"
else
  note "  FAIL expected .vibe/build/mutate/results.tsv and no run.* directory"; fail=1
fi

note "=== a test for inc kills the survivors: exit 0 ==="
cat >> "$WORK/lib_test.vibe" <<'EOF'

test "inc" {
  assert(inc(1) == 2)
}
EOF
sed 's/^  double, greet, is_adult$/  double, greet, inc, is_adult/' "$WORK/lib_test.vibe" > "$WORK/t" && mv "$WORK/t" "$WORK/lib_test.vibe"
out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe lib_test.vibe 2>>"$WORK/err")"
status=$?
[ "$status" = 0 ] && note "  ok   exit 0 without survivors" || { note "  FAIL exit $status, expected 0"; fail=1; }
expect_line "score: 7/7 killed (100.0%)"

if [ "$fail" != 0 ]; then
  note "--- stdout of the last run ---"; printf '%s\n' "$out"
  note "--- stderr ---"; cat "$WORK/err"
  exit 1
fi
note "vibe-mutate: ok"

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
#   "chatty"       kills nothing; prints a forged runner row that must be ignored
#   "adult at 18"  kills boundary, negate, const 19
#   "adult at 30"  kills negate only        -> subsumed by "adult at 18"
#   "minor at 5"   kills negate only        -> subsumed by "adult at 18"
#   "double"       kills both double sites
#   "greet"        its only site is unviable -> kills nothing
# lib_test.vibe also exports a plain `__test_helper` fn, which is not a test.
# So 8 sites: 5 killed, 2 survived (inc), 1 unviable; 6 tests, the cover keeps 2.
# The second run adds inc_test.vibe: kills are attributed per file.
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

// Not a test block: the `__test_` prefix is not reserved, so only the
// compiler's own list of test exports may decide what runs.
export fn __test_helper() -> Int {
  1
}

// Output is discarded, unbuffered: a forged row here must not be read as a
// test the runner reported.
test "chatty" {
  println("vibe::test\tok\tforged")
  assert(double(0) == 0)
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
# VIBE_TEST_BACKEND=gc is inherited on purpose: mutation runs are linear
# (the per-block runner and the authoritative test list are linear
# artifacts), so the setting must not leak into them.
out="$(cd "$WORK" && VIBE_TEST_BACKEND=gc VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
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
expect_line 'NOKILL lib_test.vibe "chatty"'
expect_line "minimal: 2 of 6 tests kill every killed mutant"
if printf '%s\n' "$out" | grep -q 'helper\|forged'; then
  note "  FAIL a non-test export or forged output was counted as a test"; fail=1
else
  note "  ok   only the compiler's test blocks were run"
fi

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

note "=== a second test file with a test for inc kills the survivors: exit 0 ==="
cat > "$WORK/inc_test.vibe" <<'EOF'
import ./lib.vibe {
  inc
}

test "inc" {
  assert(inc(1) == 2)
}
EOF
out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe lib_test.vibe inc_test.vibe 2>>"$WORK/err")"
status=$?
[ "$status" = 0 ] && note "  ok   exit 0 without survivors" || { note "  FAIL exit $status, expected 0"; fail=1; }
expect_line "score: 7/7 killed (100.0%)"
expect_line 'TEST kills=2 unique=2 inc_test.vibe "inc"'

note "=== two blocks with one title: refused, not half-measured ==="
# Only one of two same-titled blocks is callable on its own; measuring it
# twice would credit the other block with kills it never made.
cat > "$WORK/dup_test.vibe" <<'EOF'
import ./lib.vibe {
  double
}

test "same" {
  assert(double(2) == 4)
}

test "same" {
  assert(double(3) == 6)
}
EOF
dup_out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe dup_test.vibe 2>&1)"
dup_status=$?
if [ "$dup_status" != 0 ] && printf '%s' "$dup_out" | grep -q 'duplicate test title'; then
  note "  ok   refused with the duplicate title named"
else
  note "  FAIL expected a refusal naming the duplicate title (exit $dup_status)"
  printf '%s\n' "$dup_out" | tail -5
  fail=1
fi

note "=== a mutant that blocks in a host call is killed at its deadline, not a hang ==="
# The epoch deadline cannot interrupt a host import; the runner's watchdog
# must. Baseline: double(2) == 4, so no shell call. Under `*` -> `/` and
# 2 -> 3 the block blocks in `sleep 30` far past --timeout-ms 300. Without
# the watchdog each would wait the full 30 s (the epoch deadline fires only
# once the host call returns), so the run's wall time is the evidence.
cat > "$WORK/hang_test.vibe" <<'EOF'
import ./lib.vibe {
  double
}

test "hang" allows Process {
  if double(2) != 4 {
    let _ = sh_lines("sleep 30")
  }
}

test "after" {
  assert(true)
}
EOF
hang_start="$(date +%s)"
hang_out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate --timeout-ms 300 lib.vibe hang_test.vibe 2>/dev/null)"
hang_secs=$(( $(date +%s) - hang_start ))
# "after" runs behind the stuck block. The watchdog's stop leaves it not run,
# so it is run again rather than credited with a kill it never made.
if printf '%s\n' "$hang_out" | grep -qxF 'TEST kills=2 unique=2 hang_test.vibe "hang"' \
  && printf '%s\n' "$hang_out" | grep -qxF 'NOKILL hang_test.vibe "after"' && [ "$hang_secs" -lt 45 ]; then
  note "  ok   both blocking mutants killed (${hang_secs}s)"
else
  note "  FAIL expected both blocking mutants killed by \"hang\" alone (\"after\" uncredited) well under 2 x 30 s (took ${hang_secs}s)"; printf '%s\n' "$hang_out" | head -8; fail=1
fi

note "=== a title holding a NUL is still one callable block ==="
# The test list is length-prefixed, not NUL-separated: a separator byte
# would split this title in two and neither half would be callable.
cat > "$WORK/nul_test.vibe" <<'EOF'
import ./lib.vibe {
  double
}

test "nul\0title" {
  assert(double(3) == 6)
}
EOF
nul_out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe nul_test.vibe 2>/dev/null)"
if printf '%s\n' "$nul_out" | grep -qxF 'TEST kills=2 unique=2 nul_test.vibe "nul\0title"'; then
  note "  ok   ran as one block and killed both double mutants"
else
  note "  FAIL expected one block \"nul\\0title\" killing 2"; printf '%s\n' "$nul_out" | head -8; fail=1
fi

note "=== a test file whose imports do not resolve is refused, not skipped ==="
cat > "$WORK/bad_test.vibe" <<'EOF'
import ./missing.vibe {
  nothing
}

test "t" {
  assert(nothing() == 1)
}
EOF
bad_out="$(cd "$WORK" && VIBE_CLI_WASM="$CLI" VIBE_RUNNER="$RUNNER" run_bounded 900 \
  bash "$ROOT_DIR/runtime/vibe" mutate lib.vibe lib_test.vibe bad_test.vibe 2>&1)"
bad_status=$?
if [ "$bad_status" != 0 ] && printf '%s' "$bad_out" | grep -q 'cannot resolve the imports of bad_test.vibe'; then
  note "  ok   refused, naming the file"
else
  note "  FAIL expected a refusal naming bad_test.vibe (exit $bad_status)"; printf '%s\n' "$bad_out" | tail -4; fail=1
fi

if [ "$fail" != 0 ]; then
  note "--- stdout of the last run ---"; printf '%s\n' "$out"
  note "--- stderr ---"; cat "$WORK/err"
  exit 1
fi
note "vibe-mutate: ok"

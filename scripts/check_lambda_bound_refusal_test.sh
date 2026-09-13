#!/usr/bin/env bash
# Red test for check_lambda_bound_refusal.sh (#2248's rule: a gate means nothing
# until it is known to be able to fail).
#
# Four assertions, four mutations, and each mutation is checked for having LANDED
# before its verdict is believed -- an edit that matches nothing passes while
# proving nothing, which is exactly how a red test goes quietly useless.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252 -- a self-test that picks up the
# session's environment silently no-ops the cases it was written for).
unset LAMBDA_BOUND_REFUSAL_FIXTURES
unset VIBE_LAMBDA_BOUND_REFUSAL_ROOT

# WHICH COMPILER. Three of the four cases below exercise the gate's interaction
# with a compiler that actually refuses, so this self-test cannot answer from the
# committed seed the way check_telemetry_sidecar_guards_test.sh can. The selftests
# lane shares the compiler-gate matrix precisely so its companions can read the
# lane's compiler out of the environment (tests/gates/selftests/run.sh), and
# `gate_resolve_stage2` exports VIBE_STAGE2_WASM for that -- the same channel
# check_compile_only_lanes_test.sh and check_freeze_surface_test.sh take.
#
# With neither set, the gate resolves its own compiler and the GREEN CONTROL
# below fails loudly. That is the intended outcome, not a gap: a self-test whose
# subject cannot refuse has proven nothing, and saying so is the difference
# between "checked" and "unchecked" (#2248).
STAGE2_OVERRIDE="${LAMBDA_BOUND_REFUSAL_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset LAMBDA_BOUND_REFUSAL_STAGE2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_lbr_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[lambda-bound-refusal-test] FAIL: $*" >&2; exit 1; }

run_gate() { # run_gate <glob> ; prints nothing, returns the gate's status
  if [ -n "$STAGE2_OVERRIDE" ]; then
    LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" LAMBDA_BOUND_REFUSAL_FIXTURES="$1" \
      bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1
  else
    LAMBDA_BOUND_REFUSAL_FIXTURES="$1" \
      bash scripts/check_lambda_bound_refusal.sh >"$WORK/out" 2>&1
  fi
}

# GREEN control. Without it a gate that fails for an unrelated reason (no
# compiler, a broken runner) would make every red case below "pass".
if ! run_gate "fixtures/lambda_bound_dispatch_*_refused.vibe"; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated corpus; the red cases below would prove nothing"
fi

# RED 1: the program compiles. The body is the qualified fixture with the lambda
# LIFTED to a top-level binder -- the very edit the message names, so this case is
# also the proof that the named edit works. Written out rather than derived by sed:
# the mutation that matters is structural, and an edit that lands as a syntax error
# would "fail" the gate for the wrong reason while proving nothing (it did, the
# first time this was written).
mkdir -p "$WORK/r1"
cat > "$WORK/r1/lambda_bound_dispatch_lifted_refused.vibe" <<'VIBE'
trait Eq {
  equals(Self, Self) -> Bool
}

struct Pt {
  v: Int
}

impl Eq for Pt {
  equals(a: Pt, b: Pt) -> Bool {
    a.v == b.v
  }
}

impl Eq for Int {
  equals(a: Int, b: Int) -> Bool {
    a == b
  }
}

fn inner_lifted[T: Eq](a: T, b: T) -> Bool {
  T::equals(a, b)
}

fn outer_qualified[T: Eq](x: T, y: T) -> Bool {
  inner_lifted(7, 8)
}

export fn _start() -> Int {
  if outer_qualified(Pt::{ v: 1 }, Pt::{ v: 2 }) {
    1
  } else {
    0
  }
}
VIBE
if run_gate "$WORK/r1/*.vibe"; then
  fail "RED 1: the gate passed a fixture that COMPILES (the refusal is not being checked)"
fi
# The verdict must be "it compiled", which is only reachable if the lifted program
# really does compile -- so this assertion doubles as the mutation-landed check.
grep -qF 'compiled; expected a compile-time refusal' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason (the lifted program did not compile)"; }

# RED 2: refused, but for an unrelated reason. "did not compile" must not pass.
mkdir -p "$WORK/r2"
cat > "$WORK/r2/lambda_bound_dispatch_unrelated_refused.vibe" <<'VIBE'
export fn _start() -> Int {
  no_such_function_anywhere(1)
}
VIBE
if run_gate "$WORK/r2/*.vibe"; then
  fail "RED 2: the gate passed a fixture refused for an unrelated reason (it checks 'did not compile', not the message)"
fi
grep -qF 'refused without the #2737 message' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: the message is there but names no edit. Built by refusing with the
# #2737 message truncated, which is what a future edit to the message text
# would look like.
mkdir -p "$WORK/r3"
cp fixtures/lambda_bound_dispatch_qualified_refused.vibe "$WORK/r3/keep_refused.vibe"
# Targets the "names an edit" grep specifically: its pattern carries the
# ` .* to a top-level` suffix that EDIT_NEEDLE does not, so the leads-check
# below is left intact and a failure here can only come from this assertion.
sed 's/move the lambda that binds .\* to a top-level/RED3 edit clause removed/' \
  scripts/check_lambda_bound_refusal.sh > "$WORK/r3/gate.sh"
grep -q 'RED3 edit clause removed' "$WORK/r3/gate.sh" \
  || fail "RED 3 mutation did not land (the edit-clause pattern was not renamed)"
grep -q '^EDIT_NEEDLE="move the lambda that binds"$' "$WORK/r3/gate.sh" \
  || fail "RED 3 mutation hit the ordering check too; it must isolate the edit-clause assertion"
if [ -n "$STAGE2_OVERRIDE" ]; then
  VIBE_LAMBDA_BOUND_REFUSAL_ROOT="$ROOT_DIR" LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
    LAMBDA_BOUND_REFUSAL_FIXTURES="$WORK/r3/*.vibe" \
    bash "$WORK/r3/gate.sh" >"$WORK/out" 2>&1 && red3_passed=1 || red3_passed=0
else
  VIBE_LAMBDA_BOUND_REFUSAL_ROOT="$ROOT_DIR" LAMBDA_BOUND_REFUSAL_FIXTURES="$WORK/r3/*.vibe" \
    bash "$WORK/r3/gate.sh" >"$WORK/out" 2>&1 && red3_passed=1 || red3_passed=0
fi
[ "$red3_passed" -eq 0 ] \
  || fail "RED 3: the edit-clause assertion does not bind (the gate passed without the clause it demands)"
grep -qF 'refusal does not name an edit' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

# RED 5: the leads-check asserts BEGINS-WITH, not CONTAINS. This is the
# distinction Codex round 4 on #2753 found missing from the first version, so it
# is the one the red case has to exercise: point EDIT_NEEDLE at a phrase that is
# genuinely IN the message but not at its start. "Contains" would pass; "begins
# with" must fail.
mkdir -p "$WORK/r5"
cp fixtures/lambda_bound_dispatch_qualified_refused.vibe "$WORK/r5/keep_refused.vibe"
sed 's/^EDIT_NEEDLE="move the lambda that binds"$/EDIT_NEEDLE="has no witness here"/' \
  scripts/check_lambda_bound_refusal.sh > "$WORK/r5/gate.sh"
grep -q '^EDIT_NEEDLE="has no witness here"$' "$WORK/r5/gate.sh" \
  || fail "RED 5 mutation did not land (EDIT_NEEDLE was not repointed)"
# The mutation only proves anything if the phrase really is present in the
# message -- a needle that matched nothing would fail the check for the wrong
# reason and show the same verdict.
LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" LAMBDA_BOUND_REFUSAL_FIXTURES="$WORK/r5/*.vibe" \
  bash scripts/check_lambda_bound_refusal.sh >/dev/null 2>&1 || true
grep -qF 'has no witness here' "$ROOT_DIR/_build/_lambda_bound_refusal/keep_refused.wasm.diag" 2>/dev/null \
  || fail "RED 5 needle is absent from the message; the case would fail for the wrong reason"
if [ -n "$STAGE2_OVERRIDE" ]; then
  VIBE_LAMBDA_BOUND_REFUSAL_ROOT="$ROOT_DIR" LAMBDA_BOUND_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
    LAMBDA_BOUND_REFUSAL_FIXTURES="$WORK/r5/*.vibe" \
    bash "$WORK/r5/gate.sh" >"$WORK/out" 2>&1 && red5_passed=1 || red5_passed=0
else
  VIBE_LAMBDA_BOUND_REFUSAL_ROOT="$ROOT_DIR" LAMBDA_BOUND_REFUSAL_FIXTURES="$WORK/r5/*.vibe" \
    bash "$WORK/r5/gate.sh" >"$WORK/out" 2>&1 && red5_passed=1 || red5_passed=0
fi
[ "$red5_passed" -eq 0 ] \
  || fail "RED 5: the leads-check accepts a clause that merely OCCURS in the message (it is a contains, not a begins-with)"
grep -qF 'does not BEGIN with the edit' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 5 failed for the wrong reason"; }

# RED 4: an empty corpus. Silence is "unchecked", not "clean".
mkdir -p "$WORK/r4"
if run_gate "$WORK/r4/*.vibe"; then
  fail "RED 4: the gate passed with no fixtures matched"
fi
grep -qF 'no fixtures matched' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"; }

echo "[lambda-bound-refusal-test] ok (5 red cases, each mutation verified to land)"

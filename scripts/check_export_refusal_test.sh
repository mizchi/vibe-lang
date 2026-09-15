#!/usr/bin/env bash
# Red test for check_export_refusal.sh (#2248's rule: a gate means nothing until
# it is known to be able to fail).
#
# Four assertions, four mutations, and each mutation is checked for having
# LANDED before its verdict is believed -- an edit that matches nothing passes
# while proving nothing, which is exactly how a red test goes quietly useless.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252 -- a self-test that picks up the
# session's environment silently no-ops the cases it was written for).
unset EXPORT_REFUSAL_FIXTURES
unset VIBE_EXPORT_REFUSAL_ROOT

# WHICH COMPILER. Every case below exercises the gate's interaction with a
# compiler that actually refuses, so this self-test cannot answer from the
# committed seed. The selftests lane shares the compiler-gate matrix precisely so
# its companions can read the lane's compiler out of the environment
# (tests/gates/selftests/run.sh), and `gate_resolve_stage2` exports
# VIBE_STAGE2_WASM for that.
#
# With neither set, the gate resolves its own compiler and the GREEN CONTROL
# below fails loudly. That is the intended outcome, not a gap: a self-test whose
# subject cannot refuse has proven nothing (#2248).
STAGE2_OVERRIDE="${EXPORT_REFUSAL_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset EXPORT_REFUSAL_STAGE2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_expref_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[export-refusal-test] FAIL: $*" >&2; exit 1; }

run_gate() { # run_gate <glob> ; prints nothing, returns the gate's status
  if [ -n "$STAGE2_OVERRIDE" ]; then
    EXPORT_REFUSAL_STAGE2="$STAGE2_OVERRIDE" EXPORT_REFUSAL_FIXTURES="$1" \
      bash scripts/check_export_refusal.sh >"$WORK/out" 2>&1
  else
    EXPORT_REFUSAL_FIXTURES="$1" \
      bash scripts/check_export_refusal.sh >"$WORK/out" 2>&1
  fi
}

run_mutated_gate() { # run_mutated_gate <gate path> <glob>
  if [ -n "$STAGE2_OVERRIDE" ]; then
    VIBE_EXPORT_REFUSAL_ROOT="$ROOT_DIR" EXPORT_REFUSAL_STAGE2="$STAGE2_OVERRIDE" \
      EXPORT_REFUSAL_FIXTURES="$2" bash "$1" >"$WORK/out" 2>&1
  else
    VIBE_EXPORT_REFUSAL_ROOT="$ROOT_DIR" EXPORT_REFUSAL_FIXTURES="$2" \
      bash "$1" >"$WORK/out" 2>&1
  fi
}

# GREEN control. Without it a gate that fails for an unrelated reason (no
# compiler, a broken runner) would make every red case below "pass".
if ! run_gate "fixtures/typecheck/export_aggregate_*_refused.vibe"; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated corpus; the red cases below would prove nothing"
fi

# RED 1: the program COMPILES. The body is the refused fixture with the exported
# name actually DECLARED -- the very edit the message names, so this case is also
# the proof that the named edit works.
mkdir -p "$WORK/r1"
cat > "$WORK/r1/export_aggregate_declared_refused.vibe" <<'VIBE'
export {
  NotDeclaredAnywhere
}

struct NotDeclaredAnywhere {
  x: Int
}

export fn main() -> Int {
  1
}
VIBE
if run_gate "$WORK/r1/*.vibe"; then
  fail "RED 1: the gate passed a fixture that COMPILES (the refusal is not being checked)"
fi
# The verdict must be "it compiled", which is only reachable if declaring the
# name really does make the program compile -- so this doubles as the
# mutation-landed check AND as proof that the edit the message names works.
grep -qF 'compiled; expected a compile-time refusal' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason (declaring the name did not make it compile)"; }

# RED 2: refused, but for an unrelated reason. "did not compile" must not pass.
mkdir -p "$WORK/r2"
cat > "$WORK/r2/export_aggregate_unrelated_refused.vibe" <<'VIBE'
export fn main() -> Int {
  no_such_function_anywhere(1)
}
VIBE
if run_gate "$WORK/r2/*.vibe"; then
  fail "RED 2: the gate passed a fixture refused for an unrelated reason (it checks 'did not compile', not the message)"
fi
grep -qF 'refused without the #2762 message' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 2 failed for the wrong reason"; }

# RED 3: the leads-check asserts BEGINS-WITH, not CONTAINS. EDIT_NEEDLE is
# repointed at a phrase that genuinely IS in the message but not at its start.
# "Contains" would pass; "begins with" must fail. This is the distinction that
# was missing from the sibling gate until Codex round 4 on #2753.
mkdir -p "$WORK/r3"
cp fixtures/typecheck/export_aggregate_undeclared_refused.vibe \
   "$WORK/r3/export_aggregate_keep_refused.vibe"
sed 's/^EDIT_NEEDLE="declare or import "$/EDIT_NEEDLE="so a consumer importing it"/' \
  scripts/check_export_refusal.sh > "$WORK/r3/gate.sh"
grep -q '^EDIT_NEEDLE="so a consumer importing it"$' "$WORK/r3/gate.sh" \
  || fail "RED 3 mutation did not land (EDIT_NEEDLE was not repointed)"
# The mutation only proves anything if the phrase really is present in the
# message -- a needle that matched nothing would fail for the wrong reason and
# show the same verdict.
run_gate "$WORK/r3/*.vibe" || true
grep -qF 'so a consumer importing it' "$ROOT_DIR/_build/_export_refusal/export_aggregate_keep_refused.wasm.diag" 2>/dev/null \
  || fail "RED 3 needle is absent from the message; the case would fail for the wrong reason"
run_mutated_gate "$WORK/r3/gate.sh" "$WORK/r3/*.vibe" && red3_passed=1 || red3_passed=0
[ "$red3_passed" -eq 0 ] \
  || fail "RED 3: the leads-check accepts a clause that merely OCCURS in the message (it is a contains, not a begins-with)"
grep -qF 'does not BEGIN with the edit' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

# RED 4: an empty corpus. Silence is "unchecked", not "clean".
mkdir -p "$WORK/r4"
if run_gate "$WORK/r4/*.vibe"; then
  fail "RED 4: the gate passed with no fixtures matched"
fi
grep -qF 'no fixtures matched' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"; }

echo "[export-refusal-test] ok (4 red cases, each mutation verified to land)"

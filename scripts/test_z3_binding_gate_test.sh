#!/usr/bin/env bash
# Self-test for scripts/test_z3_binding_gate.sh (#2248): the gate must FAIL on
# a mutated program, and pass on an unmutated copy.
#
#   VIBE_STAGE2_WASM=<stage2.wasm> bash scripts/test_z3_binding_gate_test.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CLI="${VIBE_STAGE2_WASM:-}"
[ -n "$CLI" ] && [ -s "$CLI" ] || { echo "test_z3_binding_gate_test.sh: set VIBE_STAGE2_WASM to a stage2 compiler" >&2; exit 2; }
unset Z3_BINDING_GATE_PROGRAM

REL="_build/test_z3_binding_gate_test"
SCRATCH="$ROOT_DIR/$REL"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "[z3-binding-gate-test] FAIL $*" >&2; exit 1; }

PROG="$SCRATCH/smtlib_main.vibex"
fresh() { rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"; cp fixtures/z3/smtlib_main.vibex "$PROG"; }
mutate() { # <from> <to>
  grep -qF -- "$1" "$PROG" || fail "mutation target '$1' not in the program"
  FROM="$1" TO="$2" python3 -c 'import os,sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace(os.environ["FROM"], os.environ["TO"], 1))' "$PROG"
  grep -qF -- "$2" "$PROG" || fail "mutation did not land"
}
run_gate() { Z3_BINDING_GATE_PROGRAM="$REL/smtlib_main.vibex" bash "$ROOT_DIR/scripts/test_z3_binding_gate.sh" "$CLI" >"$SCRATCH.out" 2>&1; }
expect_fail() { # <label> <message substring>
  if run_gate; then cat "$SCRATCH.out" >&2; fail "$1: the gate passed"; fi
  grep -qF -- "$2" "$SCRATCH.out" || { cat "$SCRATCH.out" >&2; fail "$1: the gate failed for another reason"; }
  echo "ok: $1"
}

fresh
run_gate || { cat "$SCRATCH.out" >&2; fail "the gate fails on an unmutated copy"; }
echo "ok: unmutated copy passes"

# 1. A Z3 function the program no longer calls leaves the import set.
fresh; mutate "  Context::close(ctx = ctx)
" ""
expect_fail "a dropped call" "it calls: "

# 2. A program that does not type-check against z3.wasm is caught.
fresh; mutate "Context::eval_smtlib2(ctx = ctx, " "Context::eval_smtlib2(ctx = ctx, extra = 1, "
expect_fail "an ill-typed call" "vibe check"

echo "[z3-binding-gate-test] ok (3 cases)"

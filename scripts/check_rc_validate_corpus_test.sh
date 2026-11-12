#!/usr/bin/env bash
# Red test for check_rc_validate_corpus.sh (#2248's rule: a gate means nothing
# until it is known to be able to fail).
#
# The mutated input is a REAL plan: `vibe rc-validate --mutate drop-dups`
# validates each plan of a real fixture with its dup rows deleted, and
# `--mutate inflate-exit-drops` with each early-exit release one higher;
# both are plans that release more than they hold. `--mutate scalar-classes`
# reads every heap binding as planned scalar, which a gate must refuse too. Each mutation is checked for having
# LANDED before its verdict is believed -- an edit that matches nothing passes
# while proving nothing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; inherit nothing (#2252).
unset RC_VALIDATE_CORPUS_FIXTURES
unset VIBE_RC_VALIDATE_CORPUS_ROOT

# WHICH COMPILER. Every case asks a compiler that has `vibe rc-validate`, so
# this cannot answer from the committed seed. The selftests lane exports the
# lane's compiler as VIBE_STAGE2_WASM (tests/gates/selftests/run.sh).
STAGE2_OVERRIDE="${RC_VALIDATE_CORPUS_STAGE2:-${VIBE_STAGE2_WASM:-}}"
unset RC_VALIDATE_CORPUS_STAGE2

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_rc_validate_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[rc-validate-corpus-test] FAIL: $*" >&2; exit 1; }

# A real fixture whose plans give CHECKED bindings dup rows (`pass_twice`
# hands one binding to two owning calls), so deleting the dups must surface.
FIXTURE="fixtures/rc_double_release_bounded_test.vibe"
[ -f "$FIXTURE" ] || fail "the red fixture $FIXTURE is gone; pick another fixture whose plan has a dup on a checked binding"

run_gate() { # run_gate <gate path> <glob> [gate args...]
  local gate="$1" glob="$2"; shift 2
  if [ -n "$STAGE2_OVERRIDE" ]; then
    VIBE_RC_VALIDATE_CORPUS_ROOT="$ROOT_DIR" RC_VALIDATE_CORPUS_STAGE2="$STAGE2_OVERRIDE" \
      RC_VALIDATE_CORPUS_FIXTURES="$glob" bash "$gate" "$@" >"$WORK/out" 2>&1
  else
    VIBE_RC_VALIDATE_CORPUS_ROOT="$ROOT_DIR" RC_VALIDATE_CORPUS_FIXTURES="$glob" \
      bash "$gate" "$@" >"$WORK/out" 2>&1
  fi
}

# The verb itself, on the compiler the gate resolves, to see what it answers.
run_verb() { # run_verb <out> [verb args...]
  local out="$1"; shift
  . "$ROOT_DIR/scripts/resolve_stage2.sh"
  local stage2
  stage2="$(resolve_stage2 rc-validate-corpus-test "$STAGE2_OVERRIDE")"
  VIBE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" VIBE_CLI_WASM="$stage2" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/runtime/vibe" rc-validate "$@" >"$out" 2>"$out.err"
}

GATE="scripts/check_rc_validate_corpus.sh"

# GREEN control. Without it a gate that fails for an unrelated reason (no
# compiler, a broken runner) would make every red case below "pass".
if ! run_gate "$GATE" "$FIXTURE"; then
  cat "$WORK/out" >&2
  fail "the gate does not pass on the unmutated fixture; the red cases below would prove nothing"
fi
grep -qF '[rc-validate-corpus] ok (1 files' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "the green run did not validate exactly the one fixture"; }

# RED 1: a real plan with its dups deleted. First show the mutation LANDED: the
# verb's own answer gains an over-release line it does not have unmutated.
run_verb "$WORK/plain.txt" "$FIXTURE" || { cat "$WORK/plain.txt.err" >&2; fail "RED 1: the unmutated verb call failed"; }
run_verb "$WORK/mutated.txt" --mutate drop-dups "$FIXTURE" \
  || { cat "$WORK/mutated.txt.err" >&2; fail "RED 1: the mutated verb call failed"; }
if grep -qE 'more than held$' "$WORK/plain.txt"; then
  fail "RED 1: the unmutated fixture already reports an over-release; it is not a control"
fi
grep -qE '^pass_twice x -: owned value released [0-9]+ more than held$' "$WORK/mutated.txt" \
  || { cat "$WORK/mutated.txt" >&2; fail "RED 1 mutation did not land (no over-release line for pass_twice under --mutate drop-dups)"; }
if run_gate "$GATE" "$FIXTURE" --mutate drop-dups; then
  cat "$WORK/out" >&2
  fail "RED 1: the gate passed a corpus whose plan releases more than it holds"
fi
grep -qF 'found a plan that releases more than it holds' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1 failed for the wrong reason"; }

# RED 1b: the same mutation on a heap PARAMETER whose dup sits before the
# parameter-drop suffix and whose scope-end drop sits in it (Codex review on
# #3859). Deleting the dup shifts the suffix; if the seam kept the old
# boundary, the drop went uncounted and the over-release read as balanced.
PARAM_FIXTURE="fixtures/rc_validate_param_dup_drop_test.vibe"
[ -f "$PARAM_FIXTURE" ] || fail "the parameter red fixture $PARAM_FIXTURE is gone"
run_verb "$WORK/pplain.txt" "$PARAM_FIXTURE" || { cat "$WORK/pplain.txt.err" >&2; fail "RED 1b: the unmutated verb call failed"; }
if grep -qE 'more than held$' "$WORK/pplain.txt"; then
  fail "RED 1b: the unmutated parameter fixture already reports an over-release; it is not a control"
fi
run_verb "$WORK/pmutated.txt" --mutate drop-dups "$PARAM_FIXTURE" \
  || { cat "$WORK/pmutated.txt.err" >&2; fail "RED 1b: the mutated verb call failed"; }
grep -qE '^f xs -: owned value released [0-9]+ more than held$' "$WORK/pmutated.txt" \
  || { cat "$WORK/pmutated.txt" >&2; fail "RED 1b mutation did not land (no over-release line for parameter f xs under --mutate drop-dups)"; }
if run_gate "$GATE" "$PARAM_FIXTURE" --mutate drop-dups; then
  cat "$WORK/out" >&2
  fail "RED 1b: the gate passed a parameter plan that releases more than it holds"
fi

# RED 1c: an early-exit release (#3718 slice 3). Every exit-drop count one
# higher is a plan whose `return` releases a binding once more than it holds.
# The verb must see it on a path that leaves by the exit -- which it could
# not before slice 3, when every binding with an exit row was not checked.
EXIT_FIXTURE="fixtures/rc_branch_dup_exit_leak_test.vibe"
[ -f "$EXIT_FIXTURE" ] || fail "the exit red fixture $EXIT_FIXTURE is gone; pick another fixture whose plan has an exit-drop row on a checked binding"
run_verb "$WORK/eplain.txt" "$EXIT_FIXTURE" || { cat "$WORK/eplain.txt.err" >&2; fail "RED 1c: the unmutated verb call failed"; }
if grep -qE 'more than held$' "$WORK/eplain.txt"; then
  fail "RED 1c: the unmutated exit fixture already reports an over-release; it is not a control"
fi
run_verb "$WORK/emutated.txt" --mutate inflate-exit-drops "$EXIT_FIXTURE" \
  || { cat "$WORK/emutated.txt.err" >&2; fail "RED 1c: the mutated verb call failed"; }
grep -qE '^let_guard v [^ ]+: owned value released [0-9]+ more than held$' "$WORK/emutated.txt" \
  || { cat "$WORK/emutated.txt" >&2; fail "RED 1c mutation did not land (no over-release line for let_guard v under --mutate inflate-exit-drops)"; }
if run_gate "$GATE" "$EXIT_FIXTURE" --mutate inflate-exit-drops; then
  cat "$WORK/out" >&2
  fail "RED 1c: the gate passed a plan whose early exit releases more than it holds"
fi
grep -qF 'found a plan that releases more than it holds' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1c failed for the wrong reason"; }

# RED 1d: a heap value planned as scalar (#3718 slice 4). The #3240 fixture's
# `unwrap_callback` takes an `Option` of a closure -- the parameter #3241
# fixed the classification of -- so reading every heap class as scalar must
# surface it, and the gate must fail on it.
SCALAR_FIXTURE="fixtures/rc_option_payload_return_test.vibe"
[ -f "$SCALAR_FIXTURE" ] || fail "the scalar red fixture $SCALAR_FIXTURE is gone; pick another fixture with a parameter declared as an Option, tuple, Array, Map or Double"
run_verb "$WORK/splain.txt" "$SCALAR_FIXTURE" || { cat "$WORK/splain.txt.err" >&2; fail "RED 1d: the unmutated verb call failed"; }
if grep -qE 'planned as scalar$' "$WORK/splain.txt"; then
  fail "RED 1d: the unmutated fixture already reports a heap value planned as scalar; it is not a control"
fi
run_verb "$WORK/smutated.txt" --mutate scalar-classes "$SCALAR_FIXTURE" \
  || { cat "$WORK/smutated.txt.err" >&2; fail "RED 1d: the mutated verb call failed"; }
grep -qE '^unwrap_callback opt -: heap value planned as scalar$' "$WORK/smutated.txt" \
  || { cat "$WORK/smutated.txt" >&2; fail "RED 1d mutation did not land (no planned-as-scalar line for unwrap_callback opt under --mutate scalar-classes)"; }
if run_gate "$GATE" "$SCALAR_FIXTURE" --mutate scalar-classes; then
  cat "$WORK/out" >&2
  fail "RED 1d: the gate passed a plan that reads a heap parameter as scalar"
fi
grep -qF 'or a heap value it does not count' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 1d failed for the wrong reason"; }

# RED 2: the case above must depend on the gate's own failure check. A copy of
# the gate with that check disconnected must PASS the mutated corpus -- if it
# still failed, RED 1 would be proving something other than the check.
sed 's/^  if grep -qE "\$fatal_pattern" "\$WORK\/out.txt"; then$/  if false \&\& grep -qE "$fatal_pattern" "$WORK\/out.txt"; then/' \
  "$GATE" > "$WORK/gate_disconnected.sh"
grep -qF '  if false && grep -qE "$fatal_pattern" "$WORK/out.txt"; then' "$WORK/gate_disconnected.sh" \
  || fail "RED 2 mutation did not land (the gate's failure check was not disconnected)"
if ! run_gate "$WORK/gate_disconnected.sh" "$FIXTURE" --mutate drop-dups; then
  cat "$WORK/out" >&2
  fail "RED 2: a gate with its failure check disconnected still fails; RED 1 does not test that check"
fi

# RED 3: a file the verb cannot answer. An error must not read as clean.
mkdir -p "$WORK/r3"
printf 'fn broken( -> Int {\n' > "$WORK/r3/rc_unparsable.vibe"
if run_gate "$GATE" "$WORK/r3/*.vibe"; then
  fail "RED 3: the gate passed a file the verb could not answer"
fi
grep -qF 'an unanswered file is not a clean one' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 3 failed for the wrong reason"; }

# RED 4: an empty corpus. Silence is "unchecked", not "clean".
mkdir -p "$WORK/r4"
if run_gate "$GATE" "$WORK/r4/*.vibe"; then
  fail "RED 4: the gate passed with no fixtures matched"
fi
grep -qF 'no fixtures matched' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "RED 4 failed for the wrong reason"; }

echo "[rc-validate-corpus-test] ok (green control + 7 red cases, each mutation verified to land)"

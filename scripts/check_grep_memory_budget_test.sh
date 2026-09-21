#!/usr/bin/env bash
# check_grep_memory_budget_test.sh -- prove check_grep_memory_budget.sh can FAIL.
#
# #2248: a gate that has never been seen to fail certifies nothing.
#
# The gate now guards TWO contracts, and this file mutates whichever side owns
# each one:
#
#   * the GATE's own assertions, for the refusal path (#2914 (a)) -- remove an
#     assertion and the gate stops seeing its property.
#   * the DRIVER's resume stitching, for the hand-off path. No edit to the
#     gate's text can reach that: the question is whether results survive a
#     hand-off, and only the driver can lose them.
#
# Neither mutates the COMPILER, which would mean a stage2 build per case.
#
# Mutated GATE copies live in scripts/ rather than a temp dir, because the gate
# sources scripts/resolve_stage2.sh by its own dirname: a copy placed anywhere
# else dies at that source line and goes "red" for a reason that has nothing to
# do with the mutation. That failure mode has bitten this repo before -- a whole
# self-test suite red for an unrelated reason, proving nothing.
#
#   GREP_BUDGET_STAGE2=<stage2.wasm> bash scripts/check_grep_memory_budget_test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_grep_memory_budget.sh"
DRIVER="scripts/vibe_grep_bin.sh"
[ -f "$GATE" ] || { echo "grep-memory-budget-test: missing $GATE" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "grep-memory-budget-test: missing $DRIVER" >&2; exit 1; }

# #2252: inherit nothing. A variable the session hook exported would silently
# steer these runs, and a case that no-ops looks exactly like one that passed.
unset VIBE_GREP_MEMORY_BUDGET_MB
unset VIBE_GREP_MEMORY_SAFETY_FACTOR
unset VIBE_GREP_CHUNK_FILES
unset VIBE_CLI_WASM

# Resolve the compiler ONCE and hand it down. The gate uses the STRICT
# resolver, so an unresolved compiler is a refusal rather than a silent seed
# fallback -- and a refusal would redden every case for a reason that has
# nothing to do with its mutation, the exact failure this file exists to rule
# out. `VIBE_STAGE2_WASM` is what the selftests lane exports.
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2_strict grep-memory-budget-test "${GREP_BUDGET_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
export GREP_BUDGET_STAGE2="$STAGE2"

MUTANT="scripts/.check_grep_memory_budget_mutant.sh"
DRIVER_BACKUP="$(mktemp)"
cp "$DRIVER" "$DRIVER_BACKUP"
cleanup() {
  rm -f "$MUTANT"
  cp "$DRIVER_BACKUP" "$DRIVER"
  rm -f "$DRIVER_BACKUP"
}
trap cleanup EXIT

passed=0
fail() { echo "grep-memory-budget-test: FAIL: $*" >&2; exit 1; }

# Mutate, assert the mutation MATCHED, then assert the gate goes red. Checking
# the match first is the point: an edit that matches nothing leaves the target
# pristine, the gate passes, and that pass would be recorded as proof. It has
# happened in this repo.
expect_red() { # <target-file> <backup-file> <name> <sed-expr>
  local target="$1" backup="$2" name="$3" expr="$4" status=0
  cp "$backup" "$target"
  sed -i.bak "$expr" "$target"
  rm -f "$target.bak"
  if cmp -s "$backup" "$target"; then
    cp "$backup" "$target"
    fail "$name: the mutation changed NOTHING, so this case proves nothing"
  fi
  bash "$GATE" >/dev/null 2>&1 || status=$?
  cp "$backup" "$target"
  if [ "$status" = "0" ]; then
    fail "$name: the mutated file PASSED the gate; that property is not
actually being checked"
  fi
  echo "grep-memory-budget-test: ok -- $name reddens the gate (exit $status)"
  passed=$((passed + 1))
}

expect_red_gate() { # <name> <sed-expr>
  cp "$GATE" "$MUTANT.orig"
  expect_red "$MUTANT" "$GATE" "$1" "$2"
  rm -f "$MUTANT.orig"
}

# The unmutated gate must pass, or every case below is red for an unrelated
# reason.
status=0
bash "$GATE" >/dev/null 2>&1 || status=$?
[ "$status" = "0" ] || fail "the UNMUTATED gate does not pass (exit $status).
Run it directly to see why; until it does, no mutation below proves anything."
echo "grep-memory-budget-test: ok -- the unmutated gate passes"

# --------------------------------------------------- the gate's own assertions

# Property 3 stops asking for the refusal path. If the no-resume probe asks for
# resume, the sweep completes and no diagnostic is ever written -- #2914 (a)'s
# guarantee for callers that cannot restart would be ungated, and nothing else
# in this file would notice.
#
# Note this mutation targets the MUTANT copy of the gate, so the probe inside
# it is what changes; the real gate is untouched.
cp "$GATE" "$MUTANT"
expect_red "$MUTANT" "$GATE" "the refusal probe asks for resume" \
  's|env VIBE_GREP=1 |env VIBE_GREP=1 VIBE_GREP_RESUME=1 |'

# A corpus with no matches makes every comparison hold vacuously.
expect_red "$MUTANT" "$GATE" "a corpus with no matches" \
  "s|^CORPUS=.*|CORPUS=\"lib/@vibe/compiler/runtime/grep_fs.vibe\"\nPATTERN='ThisNameDoesNotExistAnywhere(\$(x:exp))'|"

# The refusal's MESSAGE is what tells a budget stop from a wasm trap: both
# produce no answer.
expect_red "$MUTANT" "$GATE" "a refusal message that never appears" \
  "s/out of memory budget before typing/a message the guard never emits/"

# ------------------------------------------------------ the driver's stitching

# Property 2 is what the resume hand-off added: a small budget must still
# answer IDENTICALLY. The way that breaks in practice is results lost around a
# hand-off, and no edit to the gate's text reaches it.
#
# 400 MB forces several hand-offs on this corpus, so dropping each process's
# last line loses real matches. Property 2's `cmp` must catch it. Property 1
# alone would not: the default budget takes one process and would lose only its
# final line, which the comparison is not against.
expect_red "$DRIVER" "$DRIVER_BACKUP" "each resumed process loses its last line" \
  's|^          cat "$out"$|          sed "$d" "$out"|'

# The resume index is ignored and the driver advances by the whole slice
# instead. Files the sweep never reached would be skipped silently -- the sweep
# stopped early and the driver reported success for the part it never asked
# about.
expect_red "$DRIVER" "$DRIVER_BACKUP" "the resume index is ignored" \
  's|^        advance="$(tr -d .\[:space:\]. < "$out.resume")"$|        advance="$slice"|'

echo "grep-memory-budget-test: ok ($passed mutations reddened the gate)"

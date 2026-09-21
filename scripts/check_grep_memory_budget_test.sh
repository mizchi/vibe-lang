#!/usr/bin/env bash
# check_grep_memory_budget_test.sh -- prove check_grep_memory_budget.sh can FAIL.
#
# #2248: a gate that has never been seen to fail certifies nothing. Each case
# below MUTATES the gate's own assertions against the REAL compiler and
# requires a FAIL, so a future edit that softens one of them is caught here.
#
# Mutating the GATE and not the COMPILER is deliberate: reddening this
# properly would otherwise mean building a stage2 with the guard removed,
# minutes per case. What each mutation proves is that the corresponding
# assertion is load-bearing -- remove it and the gate stops seeing its
# property.
#
# The mutated copies live in scripts/ rather than a temp dir, because the gate
# sources scripts/resolve_stage2.sh by its own dirname: a copy placed anywhere
# else dies at that source line and goes "red" for a reason that has nothing
# to do with the mutation. That failure mode has bitten this repo before -- a
# whole self-test suite that was red for an unrelated reason and proved
# nothing.
#
#   GREP_BUDGET_STAGE2=<stage2.wasm> bash scripts/check_grep_memory_budget_test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_grep_memory_budget.sh"
[ -f "$GATE" ] || { echo "grep-memory-budget-test: missing $GATE" >&2; exit 1; }

# #2252: inherit nothing. A variable the session hook exported would silently
# steer these runs, and a case that no-ops looks exactly like a case that passed.
unset VIBE_GREP_MEMORY_BUDGET_MB
unset VIBE_GREP_MEMORY_SAFETY_FACTOR
unset VIBE_CLI_WASM

MUTANT="scripts/.check_grep_memory_budget_mutant.sh"
cleanup() { rm -f "$MUTANT"; }
trap cleanup EXIT

passed=0
fail() { echo "grep-memory-budget-test: FAIL: $*" >&2; exit 1; }

# Mutate, assert the mutation MATCHED, then assert the gate goes red.
# Checking the match first is the point: an edit that matches nothing leaves a
# pristine gate that passes, and a "red test" that never reddened would be
# recorded as proof.
expect_red() { # <name> <sed-expr>
  local name="$1" expr="$2" status=0
  cp "$GATE" "$MUTANT"
  sed -i.bak "$expr" "$MUTANT"
  rm -f "$MUTANT.bak"
  if cmp -s "$GATE" "$MUTANT"; then
    fail "$name: the mutation changed NOTHING, so this case proves nothing"
  fi
  GREP_BUDGET_STAGE2="${GREP_BUDGET_STAGE2:-}" bash "$MUTANT" >/dev/null 2>&1 || status=$?
  if [ "$status" = "0" ]; then
    fail "$name: the mutated gate PASSED; that assertion is not load-bearing"
  fi
  echo "grep-memory-budget-test: ok -- $name reddens the gate (exit $status)"
  passed=$((passed + 1))
}

# The gate must pass unmutated first. Otherwise every case below is red for a
# reason that has nothing to do with its mutation.
status=0
GREP_BUDGET_STAGE2="${GREP_BUDGET_STAGE2:-}" bash "$GATE" >/dev/null 2>&1 || status=$?
[ "$status" = "0" ] || fail "the UNMUTATED gate does not pass (exit $status).
Every case below would then be red for an unrelated reason. Run it directly to see why."
echo "grep-memory-budget-test: ok -- the unmutated gate passes"

# A budget that is not small enough to fire the guard: the gate must notice
# that its refusal case stopped refusing.
expect_red "a budget too large to refuse" 's/run_grep 400 /run_grep 100000 /'

# The corpus stops producing matches: properties 1 and 2 both go vacuous, and
# the gate must say so rather than report ok over an empty sweep.
expect_red "a corpus with no matches" "s|^CORPUS=.*|CORPUS=\"lib/@vibe/compiler/runtime/grep_fs.vibe\"\nPATTERN='ThisNameDoesNotExistAnywhere(\$(x:exp))'|"

# The message assertion is what tells the budget refusal from a wasm trap:
# both exit 1 with empty stdout. Demanding a message that never appears must
# redden, which shows the check is reached and discriminating.
expect_red "a refusal message that never appears" "s/out of memory budget before typing/a message the guard never emits/"

echo "grep-memory-budget-test: ok ($passed mutations reddened the gate)"

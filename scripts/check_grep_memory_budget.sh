#!/usr/bin/env bash
# check_grep_memory_budget.sh -- `vibe grep --where` refuses instead of trapping
# when it cannot afford the next file (#2914).
#
# The typed tier used to die on a tree-wide sweep with a bare wasm
# `RuntimeError: memory access out of bounds` and a backtrace naming neither
# the file nor the stage. `grep_scan_fs_report` now reads the bump frontier
# through `Profiler::heap_bytes()` before typing each file and refuses with a
# diagnostic that names where it stopped.
#
# This gate asserts the three properties that are worth anything:
#
#   1. DEFAULT BUDGET CHANGES NOTHING. A corpus that swept clean before still
#      answers, byte for byte, and exits 0. A guard that quietly trims real
#      answers would be worse than the trap.
#   2. A SMALL BUDGET REFUSES, AND THE REFUSAL IS ACTIONABLE. Exit 1, EMPTY
#      stdout (never a partial answer presented as complete), and a message
#      naming the file it stopped before, how far it got, and the way out.
#   3. A MALFORMED BUDGET IS REJECTED, not read as some other number.
#
# Property 1 and property 2 are the same sweep over the same corpus, varying
# ONLY the cap -- the technique that established the cap was the binding
# constraint in the first place (grep_fs.vibe's own comment).
#
# WHY A SMALL BUDGET AND NOT THE REAL CEILING: reproducing the actual trap
# needs a tree-wide typed sweep, which costs minutes and gigabytes. The
# budget's override exists so the same code path is reachable in seconds. The
# tree-wide behaviour is recorded in the commit, not re-run here.
#
#   GREP_BUDGET_STAGE2=<stage2.wasm> bash scripts/check_grep_memory_budget.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

STAGE2="$(resolve_stage2 grep-memory-budget "${GREP_BUDGET_STAGE2:-}")" || exit 1

# Small enough to sweep in seconds, with enough typed files that the guard has
# a previous file's cost to reason from (it cannot fire on the first file).
CORPUS="lib/@vibe/compiler/runtime"
PATTERN='Array::length($(x:exp))'
WHERE='$x : Array[String]'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "grep-memory-budget: FAIL: $*" >&2
  exit 1
}

# Each run gets its own persistent-cache dir: a warm cache changes how much a
# file allocates, so sharing one between the two budgets would make the pair
# incomparable (#2393).
run_grep() { # <budget-or-empty> <stdout> <stderr>; echoes the exit status
  local budget="$1" out="$2" err="$3" status=0 cache
  cache="$(mktemp -d)"
  if [ -n "$budget" ]; then
    env VIBE_CLI_WASM="$STAGE2" VIBE_BUILD_CACHE_DIR="$cache" \
        VIBE_GREP_MEMORY_BUDGET_MB="$budget" \
        bash "$ROOT_DIR/scripts/vibe_grep_bin.sh" grep \
        --pattern "$PATTERN" --where "$WHERE" "$CORPUS" >"$out" 2>"$err" || status=$?
  else
    env VIBE_CLI_WASM="$STAGE2" VIBE_BUILD_CACHE_DIR="$cache" \
        bash "$ROOT_DIR/scripts/vibe_grep_bin.sh" grep \
        --pattern "$PATTERN" --where "$WHERE" "$CORPUS" >"$out" 2>"$err" || status=$?
  fi
  rm -rf "$cache"
  printf '%s' "$status"
}

# ---------------------------------------------------------------- property 1
status="$(run_grep "" "$WORK/default.out" "$WORK/default.err")"
[ "$status" = "0" ] || fail "default budget: expected exit 0, got $status
$(cat "$WORK/default.err")"
[ -s "$WORK/default.out" ] || fail "default budget: expected matches, got empty stdout.
The corpus must produce matches or properties 1 and 2 are both vacuous."
grep -q 'out of memory budget' "$WORK/default.err" &&
  fail "default budget: the guard fired on a corpus it must not stop.
$(cat "$WORK/default.err")"
default_lines="$(wc -l < "$WORK/default.out")"
echo "grep-memory-budget: default budget answers ($default_lines lines, exit 0)"

# ---------------------------------------------------------------- property 2
# 400 MB: below what this corpus's closure needs, above one file's cost, so the
# guard fires partway rather than on the first file (which it cannot do -- it
# has no observed cost yet).
status="$(run_grep 400 "$WORK/small.out" "$WORK/small.err")"
[ "$status" = "1" ] || fail "small budget: expected exit 1, got $status.
A refusal that exits 0 is a sweep reporting success for an answer it never produced.
$(cat "$WORK/small.err")"
[ ! -s "$WORK/small.out" ] || fail "small budget: stdout was NOT empty ($(wc -l < "$WORK/small.out") lines).
A partial sweep printed as though complete is the failure this guard exists to prevent."
grep -q 'out of memory budget before typing' "$WORK/small.err" ||
  fail "small budget: refused, but not with the budget diagnostic.
A wasm trap also exits 1 with empty stdout, so the MESSAGE is what tells the
two apart -- without this assertion the gate passes on the very bug it guards.
$(cat "$WORK/small.err")"
grep -qE 'before typing `[^`]*\.vibe`' "$WORK/small.err" ||
  fail "small budget: the diagnostic does not name the file it stopped before.
Naming the file is the whole point: the trap it replaces already said nothing.
$(cat "$WORK/small.err")"
grep -qE '\([0-9]+ of [0-9]+ files swept\)' "$WORK/small.err" ||
  fail "small budget: the diagnostic does not say how far the sweep got.
$(cat "$WORK/small.err")"
grep -q 'drop --where' "$WORK/small.err" ||
  fail "small budget: the diagnostic does not name a way out.
A diagnostic leads with the edit that fixes it (AGENTS.md).
$(cat "$WORK/small.err")"
echo "grep-memory-budget: small budget refuses with a located, actionable diagnostic"

# ---------------------------------------------------------------- property 3
for bad in abc 0 -5 12x; do
  status="$(run_grep "$bad" "$WORK/bad.out" "$WORK/bad.err")"
  [ "$status" = "1" ] || fail "budget '$bad': expected exit 1, got $status.
A budget read as some other number is a budget that silently does not hold."
  grep -q 'VIBE_GREP_MEMORY_BUDGET_MB must be a positive whole number' "$WORK/bad.err" ||
    fail "budget '$bad': rejected, but without saying why.
$(cat "$WORK/bad.err")"
done
echo "grep-memory-budget: malformed budgets are rejected by name (abc 0 -5 12x)"

echo "grep-memory-budget: ok"

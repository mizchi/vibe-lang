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
# Since the resume hand-off (#2914 adaptive), the guard has TWO callers and
# this gate gates both:
#
#   1. DEFAULT BUDGET ANSWERS. Unchanged, exit 0, non-empty.
#   2. A SMALL BUDGET STILL ANSWERS, BYTE-IDENTICALLY, through the driver.
#      The budget is now a per-process cap, not a failure threshold: the sweep
#      stops on it, says where, and a fresh process continues. Measured: 400 MB
#      returns the same 236 lines the default does. This is the property that
#      replaced "a small budget refuses" -- it is a stronger claim, because a
#      resume loop that silently dropped the files around each hand-off would
#      still exit 0.
#   3. WITHOUT RESUME, A SMALL BUDGET REFUSES. #2914 (a)'s guarantee, still
#      live for every caller that cannot restart -- a library call, or
#      `runtime/vibe` before it grows a resume loop. Exit 1, EMPTY stdout, and
#      a message naming the file it stopped before. Driven by invoking the
#      compiler directly, the way such a caller does, because the driver now
#      always asks for resume.
#   4. A MALFORMED BUDGET IS REJECTED, not read as some other number.
#
# Properties 1-3 are the same sweep over the same corpus, varying ONLY the cap
# -- the technique that established the cap was the binding constraint in the
# first place (grep_fs.vibe's own comment).
#
# WHY A SMALL BUDGET AND NOT THE REAL CEILING: reproducing the actual trap
# needs a tree-wide typed sweep, which costs minutes and gigabytes. The
# budget's override exists so the same code path is reachable in seconds. The
# tree-wide behaviour is recorded in the commit, not re-run here.
#
# WHICH COMPILER: the STRICT resolver, not the lenient one. This gate tests
# behaviour that exists only in a NEW compiler, so `resolve_stage2`'s
# degradation -- newest generation on disk, else the committed seed -- is
# always the wrong answer here: the seed has no budget guard, so the gate
# would fail while reporting nothing about the change. It failed exactly that
# way on its first CI run. The strict resolver refuses instead.
#
# `VIBE_STAGE2_WASM` is the second name because that is what the compiler-gate
# selftests lane exports; `GREP_BUDGET_STAGE2` stays first so a caller can
# still point this at one artifact specifically.
#
#   GREP_BUDGET_STAGE2=<stage2.wasm> bash scripts/check_grep_memory_budget.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

STAGE2="$(resolve_stage2_strict grep-memory-budget "${GREP_BUDGET_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1

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
# 400 MB: far below what this corpus's closure needs, so the guard fires
# partway and the driver must resume across several processes. It cannot fire
# on the first file -- it has no observed cost yet -- so progress is
# guaranteed and the sweep must finish.
status="$(run_grep 400 "$WORK/small.out" "$WORK/small.err")"
[ "$status" = "0" ] || fail "small budget: expected exit 0 (the resume hand-off
should carry the sweep across processes), got $status.
$(cat "$WORK/small.err")"
cmp -s "$WORK/default.out" "$WORK/small.out" ||
  fail "a small budget changed the answer.
The budget decides how many processes the sweep takes, not what it finds. A
hand-off that dropped the files around each boundary would still exit 0, which
is why this compares OUTPUT and not just the status.
$(diff "$WORK/default.out" "$WORK/small.out" | head -5)"
echo "grep-memory-budget: a small budget still answers identically ($(grep -c . "$WORK/small.out" || true) lines, exit 0)"

# ---------------------------------------------------------------- property 3
# The refusal #2914 (a) added is still live for a caller that CANNOT restart.
# Driven by invoking the compiler directly, without VIBE_GREP_RESUME, because
# the driver always asks for resume now and would never reach this path.
run_no_resume() { # <budget> <stdout> <stderr>; echoes the status
  local budget="$1" out="$2" err="$3" status=0 cache
  cache="$(mktemp -d)"
  rm -f "$out" "$out.diag" "$out.warn"
  env VIBE_GREP=1 \
      VIBE_GREP_PATTERN="$PATTERN" \
      VIBE_GREP_WHERE="$WHERE
" \
      VIBE_GREP_WHERE_ROW="" VIBE_GREP_ONLY="" VIBE_GREP_JSON=0 \
      VIBE_GREP_MEMORY_BUDGET_MB="$budget" \
      VIBE_IMPORT_ABI=raw VIBE_PREOPEN_DIR="$ROOT_DIR" \
      VIBE_BUILD_CACHE_DIR="$cache" \
      bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
      "$STAGE2" "$CORPUS" "$out" >/dev/null 2>"$err" || status=$?
  rm -rf "$cache"
  printf '%s' "$status"
}
run_no_resume 400 "$WORK/noresume.out" "$WORK/noresume.err" >/dev/null || true
[ -s "$WORK/noresume.out.diag" ] ||
  fail "without resume, a small budget did NOT refuse.
#2914 (a)'s guarantee is that a caller which cannot restart gets a located
diagnostic rather than a partial answer. The adaptive lane must not have
removed it -- it is the only thing standing between such a caller and a sweep
that stops early while reporting success."
grep -q 'out of memory budget before typing' "$WORK/noresume.out.diag" ||
  fail "without resume, it refused but not with the budget diagnostic.
A wasm trap also produces no answer, so the MESSAGE is what tells them apart.
$(cat "$WORK/noresume.out.diag")"
grep -qE 'before typing `[^`]*\.vibe`' "$WORK/noresume.out.diag" ||
  fail "the refusal does not name the file it stopped before.
$(cat "$WORK/noresume.out.diag")"
grep -q 'drop --where' "$WORK/noresume.out.diag" ||
  fail "the refusal does not name a way out.
$(cat "$WORK/noresume.out.diag")"
echo "grep-memory-budget: without resume, a small budget still refuses with a located diagnostic"

# ---------------------------------------------------------------- property 4
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

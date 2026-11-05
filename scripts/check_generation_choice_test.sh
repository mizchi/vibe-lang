#!/usr/bin/env bash
# Red test for scripts/check_generation_choice.vibex (#2248, #3830).
#
# Each case copies the repository's workflows and lane sources into a tree
# under _build/ (the gate reads only inside the repository), plants one
# spelling, and asserts the gate fails naming that file and line -- or, for a
# control, that it still passes. The unmutated copy must pass first, so a
# failure is attributable to the plant (#2252).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_generation_choice.vibex"
WORK="_build/generation_choice_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "generation-choice-test: FAIL: $*" >&2; exit 1; }
pass() { echo "generation-choice-test: ok: $*"; }

build_tree() { # <name>
  local t="$WORK/$1"
  rm -rf "$t"
  mkdir -p "$t/.github" "$t/tests"
  cp -R .github/workflows "$t/.github/workflows"
  cp -R tests/gates "$t/tests/gates"
}

run_gate() { # <tree name>
  bash scripts/vibe_run.sh "$GATE" -- --root "$WORK/$1" >"$WORK/out" 2>&1
}

expect_red() { # <case> <tree> <needle>
  if run_gate "$2"; then
    cat "$WORK/out" >&2
    fail "$1: the gate passed -- it cannot see that spelling"
  fi
  grep -qF -- "$3" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "$1 failed, but not for its own reason (wanted: $3)"; }
  pass "$1"
}

expect_green() { # <case> <tree>
  run_gate "$2" || { cat "$WORK/out" >&2; fail "$1: the gate rejected a tree it must accept"; }
  pass "$1"
}

# <file> <text>: append a line, and confirm it landed.
plant() {
  printf '%s\n' "$2" >> "$1"
  tail -n 1 "$1" | grep -qF -- "$2" || fail "the plant did not land in $1"
}

# --- GREEN control ------------------------------------------------------------
build_tree control
expect_green "control: the copied tree passes" control
grep -qF "[generation-choice] ok (" "$WORK/out" || fail "control: no summary line: $(cat "$WORK/out")"

# --- RED 1: the spelling #3830 removed, in a workflow -------------------------
build_tree r1
plant "$WORK/r1/.github/workflows/ci.yml" '          gen="$(ls -dt _build/selfhost/generations/*/ | head -1)"'
r1_line="$(wc -l < "$WORK/r1/.github/workflows/ci.yml" | tr -d ' ')"
expect_red "RED 1: ls -dt in a workflow" r1 ".github/workflows/ci.yml:$r1_line: picks the newest generation"

# --- RED 2: the other flag order, in a lane source one directory down ---------
build_tree r2
plant "$WORK/r2/tests/gates/late/run.sh" 'for gen in $(ls -td _build/selfhost/generations/*/); do :; done'
expect_red "RED 2: ls -td in a lane" r2 "tests/gates/late/run.sh:"

# --- RED 3: extra flags around d and t ----------------------------------------
build_tree r3
plant "$WORK/r3/tests/gates/lib.sh" 'x="$(ls -1dt _build/selfhost/generations/*/)"'
expect_red "RED 3: ls -1dt" r3 "tests/gates/lib.sh:"

# --- controls: what the rule must not touch -----------------------------------
build_tree c1
plant "$WORK/c1/.github/workflows/ci.yml" '          # never: gen="$(ls -dt _build/selfhost/generations/*/ | head -1)"'
plant "$WORK/c1/tests/gates/lib.sh" 'ls -d _build/selfhost/generations/*/ >/dev/null || true'
plant "$WORK/c1/tests/gates/lib.sh" 'x="$(ls -dt _build/other/*/ | head -1)"'
expect_green "controls: a comment, ls -d without t, and ls -dt elsewhere pass" c1

# --- RED 4: nothing to scan ---------------------------------------------------
build_tree r4
rm -rf "$WORK/r4/.github/workflows"
expect_red "RED 4: no workflows is not clean" r4 "no .github/workflows/*.yml found"
build_tree r5
rm -rf "$WORK/r5/tests/gates"
expect_red "RED 5: no lane sources is not clean" r5 "no tests/gates lane source found"

# --- the real tree ------------------------------------------------------------
bash scripts/vibe_run.sh "$GATE" >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "the repository's own tree was rejected"; }
pass "the repository's own tree passes"

echo "generation-choice-test: ok (5 red cases + 2 controls + the real tree)"

#!/usr/bin/env bash
# Red test for scripts/check_generation_choice.vibex (#2248, #3830, #3866).
#
# Each case copies the files the gate scans (workflows, lane sources, scripts,
# Taskfile.pkl, tests/fuzz, eval drivers) and its allowlist into a tree
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
  mkdir -p "$t/.github" "$t/tests" "$t/scripts" "$t/eval"
  cp -R .github/workflows "$t/.github/workflows"
  cp -R tests/gates "$t/tests/gates"
  cp -R tests/fuzz "$t/tests/fuzz"
  cp scripts/*.sh scripts/*.vibex scripts/generation_choice_allowlist.txt "$t/scripts/"
  cp -R scripts/pkfire "$t/scripts/pkfire"
  cp Taskfile.pkl "$t/Taskfile.pkl"
  local d
  for d in eval/*/; do
    mkdir -p "$t/$d"
    find "$d" -name '*.sh' -exec sh -c 'mkdir -p "$1/$(dirname "$2")" && cp "$2" "$1/$2"' _ "$t" {} \;
  done
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

# --- RED 6-9: the #3866 scopes, and `ls -t` without `-d` -----------------------
build_tree r6
plant "$WORK/r6/scripts/verify_rc.sh" 'CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm | head -1)"'
r6_line="$(wc -l < "$WORK/r6/scripts/verify_rc.sh" | tr -d ' ')"
expect_red "RED 6: ls -t (no -d) in a script" r6 "scripts/verify_rc.sh:$r6_line: picks the newest generation"
build_tree r7
plant "$WORK/r7/scripts/vibe_md.vibex" '    let r = sh_capture("ls -dt _build/selfhost/generations/*/ 2>/dev/null")'
expect_red "RED 7: a .vibex shelling out to ls -dt" r7 "scripts/vibe_md.vibex:"
build_tree r8
plant "$WORK/r8/Taskfile.pkl" '  cmd = "gen=\"$(ls -dt _build/selfhost/generations/*/ | head -1)\"; true"'
expect_red "RED 8: a task command" r8 "Taskfile.pkl:"
build_tree r9
plant "$WORK/r9/eval/lang-review/run_golden.sh" 'S2=$(ls -1t _build/selfhost/generations/*/stage2.wasm | head -1)'
plant "$WORK/r9/tests/fuzz/run_fuzz.sh" 'CLI="$(ls -t _build/selfhost/generations/*/stage2.wasm | head -1)"'
expect_red "RED 9a: an eval driver two directories down" r9 "eval/lang-review/run_golden.sh:"
grep -qF "tests/fuzz/run_fuzz.sh:" "$WORK/out" || { cat "$WORK/out" >&2; fail "RED 9b: tests/fuzz was not scanned"; }
pass "RED 9b: tests/fuzz"

# --- RED 10: the allowlist may only shrink -------------------------------------
# resolve_stage2.sh is allowlisted for its announced fallback. Rewrite that
# line away and the entry must fail as stale rather than linger.
build_tree r10
sed 's/ls -td /ls -d /' "$WORK/r10/scripts/resolve_stage2.sh" > "$WORK/r10/scripts/resolve_stage2.sh.new"
mv "$WORK/r10/scripts/resolve_stage2.sh.new" "$WORK/r10/scripts/resolve_stage2.sh"
grep -q 'ls -td ' "$WORK/r10/scripts/resolve_stage2.sh" && fail "RED 10: the rewrite did not land"
expect_red "RED 10: a stale allowlist entry" r10 "scripts/resolve_stage2.sh no longer picks by mtime"
# ... and an entry for a file that never picked fails the same way.
build_tree r11
printf 'scripts/verify_rc.sh\tno reason\n' >> "$WORK/r11/scripts/generation_choice_allowlist.txt"
expect_red "RED 11: an allowlist entry that excuses nothing" r11 "scripts/verify_rc.sh no longer picks by mtime"

# --- controls for the #3866 scopes ----------------------------------------------
build_tree c2
plant "$WORK/c2/scripts/vibe_md.vibex" '// never: sh_capture("ls -dt _build/selfhost/generations/*/")'
plant "$WORK/c2/Taskfile.pkl" '// never: gen="$(ls -dt _build/selfhost/generations/*/ | head -1)"'
plant "$WORK/c2/scripts/check_generation_choice_test.sh" 'x="$(ls -t _build/selfhost/generations/*/stage2.wasm)"'
expect_green "controls: // comments, and the gate's own self-test, pass" c2

# --- RED 4: nothing to scan ---------------------------------------------------
build_tree r4
rm -rf "$WORK/r4/.github/workflows"
expect_red "RED 4: no workflows is not clean" r4 "no .github/workflows/*.yml found"
build_tree r5
rm -rf "$WORK/r5/tests/gates"
expect_red "RED 5: no lane sources is not clean" r5 "no tests/gates lane source found"
build_tree r12
rm -f "$WORK/r12/scripts/"*.sh "$WORK/r12/scripts/"*.vibex
expect_red "RED 12: no scripts is not clean" r12 "no scripts/*.sh or scripts/*.vibex found"

# --- the real tree ------------------------------------------------------------
bash scripts/vibe_run.sh "$GATE" >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "the repository's own tree was rejected"; }
pass "the repository's own tree passes"

echo "generation-choice-test: ok (13 red cases + 3 controls + the real tree)"

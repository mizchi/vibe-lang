#!/usr/bin/env bash
# Red test for scripts/check_inline_builtin_capture.vibex (#2248). #3672 ported
# the gate; it had no self-test before.
#
# Each case plants a tree under _build/ holding FLATTENED copies of the three
# sources the gate reads (scripts/source_group.vibex) and the allowlist, mutates
# one of them, and asserts the gate fails for that mutation's own reason. The
# unmutated tree must pass first, so a failure is attributable to the mutation
# (#2252), and every mutation is checked for having LANDED before its verdict
# is believed.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_inline_builtin_capture.vibex"
CALL="lib/@vibe/compiler/codegen/expr/compile_call.vibe"
ANALYSIS="lib/@vibe/compiler/codegen/common_analysis/common_analysis.vibe"
REGISTRY="lib/@vibe/compiler/core/builtin_registry.vibe"
ALLOW="scripts/inline_builtin_capture_allowlist.txt"

# The gate reads only inside the repository, so the trees live under _build/.
WORK="_build/inline_builtin_capture_test.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "inline-builtin-capture-test: FAIL: $*" >&2; exit 1; }
pass() { echo "inline-builtin-capture-test: ok: $*"; }

# One flattened copy of each group, reused by every tree.
mkdir -p "$WORK/flat"
bash scripts/vibe_run.sh scripts/source_group.vibex -- "$CALL" > "$WORK/flat/call.vibe"
bash scripts/vibe_run.sh scripts/source_group.vibex -- "$ANALYSIS" > "$WORK/flat/analysis.vibe"

build_tree() { # <name>
  local t="$WORK/$1"
  rm -rf "$t"
  mkdir -p "$t/$(dirname "$CALL")" "$t/$(dirname "$ANALYSIS")" "$t/$(dirname "$REGISTRY")" "$t/scripts"
  cp "$WORK/flat/call.vibe" "$t/$CALL"
  cp "$WORK/flat/analysis.vibe" "$t/$ANALYSIS"
  cp "$REGISTRY" "$t/$REGISTRY"
  cp "$ALLOW" "$t/$ALLOW"
}

run_gate() { # <tree name>
  bash scripts/vibe_run.sh "$GATE" -- --root "$WORK/$1" >"$WORK/out" 2>&1
}

expect_red() { # <case> <tree name> <needle>
  if run_gate "$2"; then
    cat "$WORK/out" >&2
    fail "$1: the gate passed -- it cannot see that defect"
  fi
  grep -qF -- "$3" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "$1 failed, but not for its own reason (wanted: $3)"; }
  pass "$1"
}

# <file> <old> <new>: replace the first occurrence, and fail when it is absent.
mutate() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.stderr.write("inline-builtin-capture-test: mutation did not land in %s: %r\n" % (path, old))
    sys.exit(2)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PYEOF
}

# --- GREEN control ------------------------------------------------------------

build_tree control
run_gate control || { cat "$WORK/out" >&2; fail "control: the unmutated tree is rejected, so every red case below would prove nothing"; }
grep -qF "inline dispatches" "$WORK/out" || fail "control: no summary line: $(cat "$WORK/out")"
pass "control: the flattened tree passes"

# --- RED 1: a registration removed --------------------------------------------
# The defect itself: `assert_true` stays guarded in compile_call and leaves
# is_inlined_scalar_builtin, as #2285 would have left it had only the guard
# landed.
build_tree r1
mutate "$WORK/r1/$ANALYSIS" 'name == "assert_true"' 'name == "assert_truX"'
expect_red "RED 1: an unregistered inline dispatch" r1 "  - assert_true"

# --- RED 2: a new guarded dispatch, in the parenthesised form ----------------
# Both names must be read, not just the first one in the parentheses.
build_tree r2
printf '\nfn probe() {\n  if !prefer_bound_call && (fname == "zz_alpha" || fname == "zz_beta") {\n    ()\n  }\n}\n' >> "$WORK/r2/$CALL"
expect_red "RED 2: the first name of a parenthesised dispatch" r2 "  - zz_alpha"
grep -qF "  - zz_beta" "$WORK/out" || { cat "$WORK/out" >&2; fail "RED 2: the second name of a parenthesised dispatch was not read"; }
pass "RED 2: the second name of a parenthesised dispatch"

# ...and the control: a measured allowlist row exempts exactly those names.
printf 'zz_alpha  test-row\nzz_beta  test-row\n' >> "$WORK/r2/$ALLOW"
run_gate r2 || { cat "$WORK/out" >&2; fail "RED 2 control: allowlisted names were still reported"; }
pass "RED 2 control: an allowlist row exempts its name"

# --- RED 3: a stale allowlist row ---------------------------------------------
build_tree r3
printf 'zz_never_dispatched  stale-row\n' >> "$WORK/r3/$ALLOW"
expect_red "RED 3: a stale allowlist row" r3 "allowlisted names that are no longer inline-dispatched"

# --- RED 4: a func-table row that is no longer linear -------------------------
# A name the linear func table covers needs no registration; take one out of
# the table and it must be reported. `Env::get` is guarded inline nowhere, so
# the case adds the guard first and checks the control passes with the row.
build_tree r4
printf '\nfn probe() {\n  if !prefer_bound_call && fname == "Env::get" {\n    ()\n  }\n}\n' >> "$WORK/r4/$CALL"
run_gate r4 || { cat "$WORK/out" >&2; fail "RED 4 control: a linear func-table name was reported"; }
pass "RED 4 control: a linear func-table name needs no registration"
mutate "$WORK/r4/$REGISTRY" '("Env::get", CtFn(reg_p1(CtString), CtString, Some("Env")), true,' '("Env::get", CtFn(reg_p1(CtString), CtString, Some("Env")), false,'
expect_red "RED 4: a name the linear func table no longer covers" r4 "  - Env::get"

# --- RED 5: the spellings the gate reads change -------------------------------
# Silence is unchecked, not clean.
build_tree r5
python3 - "$WORK/r5/$CALL" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
t = s.replace("!prefer_bound_call &&", "!prefer_bound_callX &&")
if t == s:
    sys.exit(2)
open(p, "w", encoding="utf-8").write(t)
PYEOF
expect_red "RED 5: no inline dispatch found" r5 "found no inline dispatches"

build_tree r6
python3 - "$WORK/r6/$ANALYSIS" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
t = s.replace("fn is_inlined_", "fn is_inlinedX_")
if t == s:
    sys.exit(2)
open(p, "w", encoding="utf-8").write(t)
PYEOF
expect_red "RED 6: no registered name found" r6 "found no registered names"

build_tree r7
rm "$WORK/r7/$REGISTRY"
expect_red "RED 7: a missing source" r7 "missing $REGISTRY"

# --- the real tree ------------------------------------------------------------

bash scripts/vibe_run.sh "$GATE" >"$WORK/out" 2>&1 \
  || { cat "$WORK/out" >&2; fail "the repository's own tree was rejected"; }
pass "the repository's own tree passes"

echo "inline-builtin-capture-test: ok (7 red cases + 3 controls + the real tree)"

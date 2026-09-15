#!/usr/bin/env bash
# Self-test for check_documented_decls.sh (#2248: a gate means nothing until
# it is shown it CAN fail).
#
# The mutation is the defect #2822 names: two `///` blocks become one block
# attached to a single declaration, and the documented count drops by one.
# The self-test first asserts that mutation actually landed -- an edit that
# matches nothing passes while proving nothing.
set -euo pipefail

# #2252: never inherit the knobs under test. Each case sets them explicitly.
unset DOC_DECL_ROOT DOC_DECL_FLOOR DOC_DECL_EXPECTED_UNREADABLE \
      DOC_DECL_NO_BATCH DOC_DECL_FALLBACK_CAP DOC_DECL_ROOT_DIR \
      VIBE_REVIEW_LINT_GREP_BIN || true

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="$ROOT_DIR/scripts/check_documented_decls.sh"
WORK="$ROOT_DIR/_build/_documented_decls_selftest"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# Two separately documented functions. Consecutive `///` lines would be ONE
# block; the blank line plus `fn a` between them is what keeps the count at 2.
separated_src() {
  cat <<'VIBE'
/// first
fn a() -> Int {
  1
}

/// second
fn b() -> Int {
  2
}
VIBE
}

fresh_tree() { # <dir>
  rm -rf "$1"; mkdir -p "$1"
  separated_src > "$1/pair.vibe"
}

floor_for() { # <path> <count>
  printf '%s\t%s\n' "$1" "$2"
}

run_gate() { # <tree> <floor-file>
  DOC_DECL_ROOT="$1" DOC_DECL_FLOOR="$2" \
    bash "$GATE" 2>&1 || return $?
}

merge_docs() { # <file>
  python3 - "$1" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = "/// first\nfn a() -> Int {\n  1\n}\n\n/// second\nfn b() -> Int {\n  2\n}\n"
new = "/// first\n/// second\nfn a() -> Int {\n  1\n}\n\nfn b() -> Int {\n  2\n}\n"
if old not in text:
    sys.stderr.write("mutation: source did not contain the separated blocks\n")
    sys.exit(1)
p.write_text(text.replace(old, new, 1))
PY
}

TREE="$WORK/tree"
FLOOR="$WORK/floor.txt"

# --- 0. GREEN control -------------------------------------------------------
fresh_tree "$TREE"
floor_for "$TREE/pair.vibe" 2 > "$FLOOR"
if out="$(run_gate "$TREE" "$FLOOR")"; then
  ok "two separately documented functions at their floor are accepted"
else
  bad "the separated control was rejected: $out"
fi

# --- 1. RED: merge the two /// blocks onto one declaration ------------------
fresh_tree "$TREE"
floor_for "$TREE/pair.vibe" 2 > "$FLOOR"
# The exact defect: concatenate the two blocks in front of `fn a`, leave `fn b`
# standing with no doc. Declarations stay 2; documented drops 2 -> 1.
if ! merge_docs "$TREE/pair.vibe"; then
  bad "mutation 1 did not apply"
elif ! awk 'prev == "/// first" && $0 == "/// second" { found = 1 } { prev = $0 } END { exit found ? 0 : 1 }' "$TREE/pair.vibe"; then
  bad "mutation 1 did not land: /// first is not immediately followed by /// second"
elif ! grep -q 'fn a()' "$TREE/pair.vibe" || ! grep -q 'fn b()' "$TREE/pair.vibe"; then
  bad "mutation 1 deleted a declaration -- the count drop would then be from removing a fn, not from merging docs"
elif out="$(run_gate "$TREE" "$FLOOR")"; then
  bad "merged /// blocks were accepted (documented count should have dropped): $out"
else
  case "$out" in
    *"dropped"*) ok "merging two /// blocks onto one declaration fails, and names the drop" ;;
    *) bad "rejected, but not about a documented-count drop: $out" ;;
  esac
fi

# --- 2. GREEN: the same merge, with the floor lowered in the same change ----
fresh_tree "$TREE"
if ! merge_docs "$TREE/pair.vibe"; then
  bad "mutation 2 did not apply"
fi
floor_for "$TREE/pair.vibe" 1 > "$FLOOR"
if out="$(run_gate "$TREE" "$FLOOR")"; then
  ok "a deliberate merge that lowers the floor in the same change is accepted"
else
  bad "a merge with the floor lowered was still rejected: $out"
fi

# --- 3. RED: a documented file with no floor row ----------------------------
fresh_tree "$TREE"
: > "$FLOOR"
if out="$(run_gate "$TREE" "$FLOOR")"; then
  bad "a documented file with no floor row was accepted: $out"
else
  case "$out" in
    *"no floor row"*) ok "a documented file with no floor row is rejected" ;;
    *) bad "rejected, but not about a missing floor row: $out" ;;
  esac
fi

if [ "$fail" -ne 0 ]; then
  echo "documented-decls-test: $fail failed, $pass passed" >&2
  exit 1
fi
echo "documented-decls-test: ok ($pass passed)"

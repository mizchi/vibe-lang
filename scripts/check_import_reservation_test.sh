#!/usr/bin/env bash
# Red test for check_import_reservation.py (#2248: a gate means nothing until
# it is shown to be able to FAIL).
#
# The mutation reconstructs #2905 exactly: `Console::read_char` is mapped onto
# `stdin_read_char_idx`, and the `|| Map::has_key(used_builtin_names,
# "Console::read_char")` clause that RESERVES that import is removed. That is
# the tree as it stood before 25ef5f77, on which a program using only the
# `Console::` spelling built clean, wrote a `.wasm`, reported success, and
# emitted a module wasmtime rejects.
#
# Case 3 is the one that matters most: mutating the MAP instead of the
# reservation must leave the gate green, because a name that is not mapped onto
# a conditional import cannot exhibit the bug. Without it, a gate that simply
# failed on any edit to this file would pass case 2 and prove nothing.
#
# Environment: every variable the gate reads is unset first (#2252), then set
# explicitly per case.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

unset VIBE_IMPORT_RESERVATION_LINKED VIBE_IMPORT_RESERVATION_REGISTRY || true

GATE="$ROOT_DIR/scripts/check_import_reservation.py"
LINKED="$ROOT_DIR/lib/@vibe/compiler/codegen/wasi/linked_compile.vibe"
REGISTRY="$ROOT_DIR/lib/@vibe/compiler/core/builtin_registry.vibe"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_import_reservation_selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "import-reservation-selftest: FAIL: $1" >&2; exit 1; }

# --- GREEN: the gate passes on the tree. ------------------------------------
if ! python3 "$GATE" >"$WORK/green.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/green.log" >&2
  fail "the gate does not pass on an unmutated tree, so a red below would prove nothing"
fi

# The green run must have CHECKED something. "ok (0 ...)" is a gate that looked
# at nothing, and it would pass every case below for the wrong reason.
checked="$(sed -n 's/^import-reservation: ok (\([0-9][0-9]*\) .*/\1/p' "$WORK/green.log")"
[ -n "$checked" ] || fail "the green run did not report how many spellings it checked"
[ "$checked" -ge 10 ] || fail "the green run checked only $checked spellings; the parser has drifted"

# --- mutate: drop the reservation clause, keep the mapping. -----------------
python3 - "$LINKED" "$WORK/mutated_linked.vibe" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
clause = ' || Map::has_key(used_builtin_names, "Console::read_char")'
if clause not in s:
    sys.stderr.write(
        "import-reservation-selftest: the mutation target is not present -- the "
        "`Console::read_char` reservation clause in linked_compile.vibe no longer "
        "has the shape this test removes. Update the test.\n")
    raise SystemExit(2)
open(dst, "w").write(s.replace(clause, "", 1))
PY
[ $? -eq 0 ] || fail "could not build the mutated input"

# THE MUTATION MUST HAVE LANDED. A red test whose edit missed is a test that
# passes while proving nothing (#2248: this has actually happened here).
if ! cmp -s "$LINKED" "$WORK/mutated_linked.vibe"; then :; else
  fail "the mutated copy is byte-identical to the original; the edit did not land"
fi
grep -q '"Console::read_char" =>' "$WORK/mutated_linked.vibe" \
  || fail "the mutation removed the MAPPING too; it must remove only the reservation"
grep -q 'Map::has_key(used_builtin_names, "Console::read_char")' "$WORK/mutated_linked.vibe" \
  && fail "the reservation clause survived the mutation"

# --- RED: the gate must fail, and must NAME the spelling. -------------------
if VIBE_IMPORT_RESERVATION_LINKED="$WORK/mutated_linked.vibe" \
   python3 "$GATE" >"$WORK/red.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/red.log" >&2
  fail "the gate PASSED on a tree carrying #2905; it cannot detect what it exists to detect"
fi
grep -q 'Console::read_char' "$WORK/red.log" \
  || fail "the gate failed but did not name Console::read_char, so it does not say what to fix"
grep -q 'stdin_read_char_idx' "$WORK/red.log" \
  || fail "the gate failed but did not name the import index the spelling lowers onto"

# --- GREEN AGAIN: an unrelated edit to the same file must not fail. ---------
# Removing a MAPPING removes the hazard rather than creating one. If this went
# red, the gate would be reacting to the file changing, not to the property.
python3 - "$LINKED" "$WORK/unmapped_linked.vibe" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
import re
m = re.search(r'^\s*"Console::read_char" => stdin_read_char_idx,\n', s, re.M)
if not m:
    sys.stderr.write("import-reservation-selftest: could not find the mapping row to remove. "
                     "Update the test.\n")
    raise SystemExit(2)
open(dst, "w").write(s[:m.start()] + s[m.end():])
PY
[ $? -eq 0 ] || fail "could not build the unmapped input"
grep -q '"Console::read_char" => stdin_read_char_idx,' "$WORK/unmapped_linked.vibe" \
  && fail "the control mutation did not land; the mapping row is still there"
if ! VIBE_IMPORT_RESERVATION_LINKED="$WORK/unmapped_linked.vibe" \
     python3 "$GATE" >"$WORK/control.log" 2>&1; then
  echo "--- gate output ---" >&2; cat "$WORK/control.log" >&2
  fail "the gate failed on a tree with NO hazard; it is reacting to the edit, not the property"
fi

# --- The drift guards must fire. --------------------------------------------
# Every `die("... has drifted")` branch exists because a silent zero-match
# would make this gate report ok forever. Prove each one is reachable.
: >"$WORK/empty.vibe"
if VIBE_IMPORT_RESERVATION_LINKED="$WORK/empty.vibe" \
   python3 "$GATE" >"$WORK/drift.log" 2>&1; then
  fail "the gate reported ok with an EMPTY input; a parser drift would pass silently"
fi
grep -q 'drifted' "$WORK/drift.log" \
  || fail "the empty-input failure did not name drift, so the cause would be misread"

if VIBE_IMPORT_RESERVATION_REGISTRY="$WORK/empty.vibe" \
   python3 "$GATE" >"$WORK/drift2.log" 2>&1; then
  fail "the gate reported ok with an EMPTY registry; a parser drift would pass silently"
fi
grep -q 'drifted' "$WORK/drift2.log" \
  || fail "the empty-registry failure did not name drift"

echo "import-reservation-selftest: ok (green on $checked spellings; red names Console::read_char; unmapped control stays green; 2 drift guards fire)"

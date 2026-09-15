#!/usr/bin/env bash
# Red test for scripts/check_builtin_parity.sh (#2248, #2584).
#
# The registry row is a 9-tuple since #2584. The gate used to anchor on
# `bool, bool, bool)`, which consumed the LAST three bools of a 9-tuple as
# if they were the lane flags. Measured on #2845: Array::push (and every
# other allocating, non-borrow-returning name) was reported as a dead row
# claiming neither lane, while the first three bools still said both lanes.
#
# Two mutations, on a COPY of the real registry. Each asserts the mutation
# LANDED before trusting the failure, and the gate is green on the unmutated
# copy first so a failure is attributable to the mutation (#2252).
set -euo pipefail

unset VIBE_BUILTIN_PARITY_REGISTRY

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_builtin_parity.sh"
REAL="lib/@vibe/compiler/core/builtin_registry.vibe"
WORK="${TMPDIR:-/tmp}/vibe_builtin_parity_selftest.$$"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "builtin-parity-selftest: FAIL: $*" >&2; exit 1; }

# --- GREEN ------------------------------------------------------------------
if ! VIBE_BUILTIN_PARITY_REGISTRY="$REAL" bash "$GATE" >"$WORK/green.log" 2>&1; then
  cat "$WORK/green.log" >&2
  fail "the gate does not pass on the tree as committed, so a later failure would prove nothing"
fi

# <case> <python mutation> <needle the failure must mention>
run_case() {
  local name="$1" mutation="$2" needle="$3"
  local copy="$WORK/$name.vibe"
  cp "$REAL" "$copy"
  python3 - "$copy" "$mutation" <<'PY'
import sys
path, which = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
before = s
needle = (
    '("Array::push", CtFn(reg_p2(CtArray(reg_var(0)), reg_var(0)), CtUnit, None), '
    "true, true, true, false, false, false, true)"
)
if which == "shape":
    repl = (
        '("Array::push", CtFn(reg_p2(CtArray(reg_var(0)), reg_var(0)), CtUnit, None), '
        "true, true, true)"
    )
elif which == "neither":
    repl = (
        '("Array::push", CtFn(reg_p2(CtArray(reg_var(0)), reg_var(0)), CtUnit, None), '
        "false, false, true, false, false, false, true)"
    )
else:
    sys.stderr.write(f"builtin-parity-selftest: unknown mutation '{which}'\n")
    sys.exit(2)
if needle not in s:
    sys.stderr.write("builtin-parity-selftest: Array::push 9-tuple not found\n")
    sys.exit(2)
s = s.replace(needle, repl, 1)
if s == before:
    sys.stderr.write(f"builtin-parity-selftest: mutation '{which}' matched nothing\n")
    sys.exit(2)
open(path, "w", encoding="utf-8").write(s)
PY
  if ! diff -q "$REAL" "$copy" >/dev/null 2>&1; then :; else
    fail "mutation '$name' did not change the copy"
  fi
  if VIBE_BUILTIN_PARITY_REGISTRY="$copy" bash "$GATE" >"$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    fail "the gate PASSED with mutation '$name' applied -- it cannot see that defect"
  fi
  if ! grep -qi "$needle" "$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    fail "mutation '$name' failed, but not for its own reason (wanted /$needle/)"
  fi
  echo "builtin-parity-selftest:   red ok: $name"
}

# A 5-tuple row must not be silently skipped: parsed-count vs named-CtFn
# count is the shape check that `len(rows) < 90` cannot provide (dropping
# one of 170+ still clears 90).
run_case shape   shape   "9-tuple"
# Lane flags are the FIRST three bools. Clearing them on Array::push must
# name that row as a dead neither-lane entry.
run_case neither neither "NEITHER lane"

echo "builtin-parity-selftest: ok"

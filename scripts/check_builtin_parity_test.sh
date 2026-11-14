#!/usr/bin/env bash
# Red test for scripts/check_builtin_parity.vibex (#2248, #2584; #3672 ported
# the gate).
#
# The registry row carries seven flags since #2584 (a `NAME TYPE FLAGS` line of
# `registry_rows_text` since #2503). The gate once anchored on the LAST three
# of them as if they were the lane flags. Measured on #2845: Array::push (and
# every other allocating, non-borrow-returning name) was reported as a dead
# row claiming neither lane, while the first three flags still said both.
#
# Two mutations, on a COPY of the real registry. Each asserts the mutation
# LANDED before trusting the failure, and the gate is green on the unmutated
# copy first so a failure is attributable to the mutation (#2252).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_builtin_parity.vibex"
REAL="lib/@vibe/compiler/core/builtin_registry.vibe"
# The gate reads only inside the repository, so the copies live under _build/.
WORK="_build/builtin_parity_selftest.$$"
rm -rf "$WORK"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "builtin-parity-selftest: FAIL: $*" >&2; exit 1; }

# The gate, pointed at a copy by one of --registry / --lin-callsite /
# --gc-callsite.
gate() { bash scripts/vibe_run.sh "$GATE" -- "$@"; }

# --- GREEN ------------------------------------------------------------------
if ! gate --registry "$REAL" >"$WORK/green.log" 2>&1; then
  cat "$WORK/green.log" >&2
  fail "the gate does not pass on the tree as committed, so a later failure would prove nothing"
fi

# <case> <python mutation> <needle the failure must mention>
run_case() {
  local name="$1" mutation="$2" needle="$3"
  local copy="$WORK/$name.vibe"
  cp "$REAL" "$copy"
  python3 - "$copy" "$mutation" <<'PY'
import re, sys
path, which = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
before = s
# Only the FLAGS column changes; the type code is kept as written.
row = re.search(r'(?P<head>#\|Array::push \S+ )(?P<flags>TTTFFFT)\n', s)
if row is None:
    sys.stderr.write("builtin-parity-selftest: Array::push row not found\n")
    sys.exit(2)
needle = row.group(0)
if which == "shape":
    repl = row.group("head") + "TTT\n"
elif which == "neither":
    repl = row.group("head") + "FFTFFFT\n"
else:
    sys.stderr.write(f"builtin-parity-selftest: unknown mutation '{which}'\n")
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
  if gate --registry "$copy" >"$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    fail "the gate PASSED with mutation '$name' applied -- it cannot see that defect"
  fi
  if ! grep -qi "$needle" "$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    fail "mutation '$name' failed, but not for its own reason (wanted /$needle/)"
  fi
  echo "builtin-parity-selftest:   red ok: $name"
}

# A row with too few flags must not be silently skipped: parsed rows vs row
# lines is the shape check that `len(rows) < 90` cannot provide (dropping
# one of 190+ still clears 90).
run_case shape   shape   "seven T/F flags"
# Lane flags are the FIRST three bools. Clearing them on Array::push must
# name that row as a dead neither-lane entry.
run_case neither neither "NEITHER lane"

# --- the checker-only rows (#3730) -----------------------------------------
#
# The 32-bit integer conversions claim neither lane because
# `rewrite_int32_stmts` removes every use before code generation. The
# exemption reads that pass, so a rewrite that stops spelling a name must
# fail the gate naming it.
INT32_REAL="lib/@vibe/compiler/normalize/desugar/int32.vibe"
INT32_COPY="$WORK/int32_rewrite.vibe"
# Only the dispatch arm is renamed: the name stays spelled in
# i32_is_conversion and i32_qualified, which must not satisfy the gate.
sed 's/} else if name == "Int::wrap_uint32" {/} else if name == "Int::wrap_uint32_gone" {/' "$INT32_REAL" > "$INT32_COPY"
if ! grep -q '"Int::wrap_uint32"' "$INT32_COPY"; then
  fail "mutation 'int32-rewrite' removed every spelling, so it would not tell an arm check from a name check"
fi
if diff -q "$INT32_REAL" "$INT32_COPY" >/dev/null 2>&1; then
  fail "mutation 'int32-rewrite' did not change the copy"
fi
if gate --int32-rewrite "$INT32_COPY" >"$WORK/int32.log" 2>&1; then
  cat "$WORK/int32.log" >&2
  fail "the gate PASSED although the Int32 rewrite no longer has an Int::wrap_uint32 arm"
fi
if ! grep -q "no longer rewritten.*Int::wrap_uint32" "$WORK/int32.log"; then
  cat "$WORK/int32.log" >&2
  fail "mutation 'int32-rewrite' failed, but not for its own reason"
fi
echo "builtin-parity-selftest:   red ok: int32-rewrite"

# --- the call-site exemption (#2397) ----------------------------------------
#
# `abort` claims neither lane HONESTLY: both lanes lower it at the call site
# rather than registering a func-table row. An exemption that is merely a name
# on a list would keep the row alive after its lowering was deleted or
# renamed, which is the same "unchecked, not clean" failure #2248 is about. So
# the exemption reads the arms, and this case proves it does: rename the gc
# arm on a COPY and the gate must name `abort` rather than waving it through.
GC_CALLSITE_REAL="$WORK/gc_original.vibe"
bash scripts/vibe_run.sh scripts/source_group.vibex -- lib/@vibe/compiler/codegen/gc/backend_call.vibe > "$GC_CALLSITE_REAL"
GC_COPY="$WORK/backend_call.vibe"
sed 's/fname == "abort"/fname == "abort_MUTATED"/' "$GC_CALLSITE_REAL" > "$GC_COPY"
grep -qF 'fname == "abort_MUTATED"' "$GC_COPY" \
  || fail "callsite mutation did not land (the gc abort arm was not renamed)"
if grep -qF 'fname == "abort"' "$GC_COPY"; then
  fail "callsite mutation left an unrenamed gc abort arm; the case would prove nothing"
fi
if gate --gc-callsite "$GC_COPY" >"$WORK/callsite.log" 2>&1; then
  cat "$WORK/callsite.log" >&2
  fail "the gate PASSED with the gc abort lowering renamed -- the exemption is a bare name, not a check"
fi
if ! grep -qi "call-site-lowered builtin has no" "$WORK/callsite.log"; then
  cat "$WORK/callsite.log" >&2
  fail "the callsite mutation failed, but not for its own reason"
fi
echo "builtin-parity-selftest:   red ok: callsite-exemption"

# The directory surface has a registry signature but no func-table slot.
# Removing either real lowering must fail, even with the spelling left in a
# comment. This is a served surface, not permission to add arbitrary dead rows.
for lane in LIN GC; do
  if [ "$lane" = LIN ]; then
    source_path="lib/@vibe/compiler/codegen/expr/compile_call.vibe"
    flag="--lin-callsite"
  else
    source_path="lib/@vibe/compiler/codegen/gc/backend_call.vibe"
    flag="--gc-callsite"
  fi
  original="$WORK/directory_$lane.original.vibe"
  copy="$WORK/directory_$lane.vibe"
  bash scripts/vibe_run.sh scripts/source_group.vibex -- "$source_path" > "$original"
  python3 - "$original" "$copy" <<'PY'
import sys
src, dst = sys.argv[1:]
s = open(src, encoding="utf-8").read()
needle = 'fname == "Fs::readdir"'
assert s.count(needle) == 1, "directory dispatch arm not found exactly once"
mutated = s.replace(needle, 'fname == "Fs::readdir_MUTATED"', 1)
assert needle not in mutated, "directory dispatch arm was not removed"
open(dst, "w", encoding="utf-8").write(mutated + "\n// " + needle + "\n")
PY
  if gate "$flag" "$copy" >"$WORK/directory_$lane.log" 2>&1; then
    cat "$WORK/directory_$lane.log" >&2
    fail "the gate PASSED with the $lane directory arm replaced by a comment"
  fi
  if ! grep -qF 'call-site-lowered builtin has no' "$WORK/directory_$lane.log" || \
     ! grep -qF 'Fs::readdir' "$WORK/directory_$lane.log"; then
    cat "$WORK/directory_$lane.log" >&2
    fail "the $lane directory mutation failed for another reason"
  fi
  echo "builtin-parity-selftest:   red ok: directory-callsite-$lane"
done

# The GC future rows remain classified as linear-only only while their
# callsite condition refuses builtin calls and preserves user shadowing.
FUTURE_COPY="$WORK/backend_future_call.vibe"
python3 - "$GC_CALLSITE_REAL" "$FUTURE_COPY" <<'PY'
import sys
from pathlib import Path
src, dst = sys.argv[1:]
s = open(src, encoding="utf-8").read()
positional = 'gc_name_is_user_defined(ctx, local_names, fname)'
named = 'gc_name_is_user_defined(ctx = ctx, local_names = local_names, name = fname)'
guards = ['fname == "Future::resolve") && !' + call for call in [positional, named]]
found = [guard for guard in guards if guard in s]
assert len(found) == 1, "GC future refusal guard not found in either argument spelling"
needle = found[0]
assert s.count(needle) == 1, "GC future refusal guard not found exactly once"
open(dst, "w", encoding="utf-8").write(s.replace(needle, needle.replace(' && !', ' && '), 1))
for style, call in [('positional', positional), ('named', named),
                    ('wrong_label', named.replace('name = fname', 'wrong_name = fname'))]:
    replacement = 'fname == "Future::resolve") && !' + call
    Path(dst).with_name('future_' + style + '.vibe').write_text(s.replace(needle, replacement, 1), encoding="utf-8")
PY
for style in positional named; do
  if ! gate --gc-callsite "$WORK/future_$style.vibe" >"$WORK/future_$style.log" 2>&1; then
    cat "$WORK/future_$style.log" >&2
    fail "the valid $style future guard was rejected"
  fi
done
echo "builtin-parity-selftest:   green ok: positional and named gc-future guards"
if gate --gc-callsite "$FUTURE_COPY" >"$WORK/future.log" 2>&1; then
  cat "$WORK/future.log" >&2
  fail "the gate PASSED after the GC future shadowing guard changed"
fi
if ! grep -qF 'GC guest future rejection shape changed' "$WORK/future.log"; then
  cat "$WORK/future.log" >&2
  fail "the future-guard mutation failed for another reason"
fi
echo "builtin-parity-selftest:   red ok: gc-future-refusal"

if gate --gc-callsite "$WORK/future_wrong_label.vibe" >"$WORK/future_wrong_label.log" 2>&1; then
  fail "the gate PASSED with the wrong GC future parameter label"
fi
grep -qF 'GC guest future rejection shape changed' "$WORK/future_wrong_label.log" || {
  cat "$WORK/future_wrong_label.log" >&2
  fail "the wrong-label mutation failed for another reason"
}
echo "builtin-parity-selftest:   red ok: gc-future-parameter-label"

echo "builtin-parity-selftest: ok"

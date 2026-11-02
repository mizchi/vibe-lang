#!/usr/bin/env bash
# Self-test for scripts/check_canonical_iterator_calls.vibex (#2248, #3672).
#
# A synthetic tree is planted under _build/ (the gate reads only inside the
# repository) and the gate is asserted red on each legacy call, green on the
# canonical spellings and on the AsyncIter entry, and red on a tree it cannot
# scan. The real tree must pass too.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_REL="_build/canonical_iterator_calls_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "canonical Iterator calls self-test: $*" >&2; exit 1; }
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_canonical_iterator_calls.vibex -- "$@" > "$WORK/out" 2>&1; }

gate || { cat "$WORK/out" >&2; fail "the real tree must pass"; }
grep -q '^canonical Iterator calls: ok (' "$WORK/out" || { cat "$WORK/out" >&2; fail "the real tree did not report ok"; }

tree="$WORK/tree"
mkdir -p "$tree/book/en" "$tree/examples/wasm" "$tree/bench/exec" "$tree/fixtures"
printf '%s\n' 'Array::map(xs, f)' > "$tree/book/en/chapter.vibe.md"
printf '%s\n' 'Array::filter(xs, pred)' > "$tree/examples/example.vibe"
printf '%s\n' 'let n = 1' 'Array::find(xs, pred)' > "$tree/examples/wasm/nested.vibe"
# Outside book/ and examples/: not the gate's corpus.
printf '%s\n' 'Array::fold(xs, 0, add)' > "$tree/bench/exec/scenario.vibe"
printf '%s\n' 'Array::map(xs, f)' > "$tree/fixtures/compatibility_test.vibe"

if gate --root "$WORK_REL/tree"; then
  cat "$WORK/out" >&2; fail "expected legacy tutorial and example calls to fail"
fi
[ "$(grep -c 'Array::' "$WORK/out")" -eq 3 ] \
  || { cat "$WORK/out" >&2; fail "expected exactly the three book/examples calls, including the nested example"; }
grep -qxF 'examples/wasm/nested.vibe:2:Array::find(xs, pred)' "$WORK/out" \
  || { cat "$WORK/out" >&2; fail "a finding must name the file and line relative to the tree"; }

# A longer identifier that only starts with a legacy name is not a call of it.
printf '%s\n' 'Array::map_with_index(xs, f)' 'Array::finder' > "$tree/book/en/chapter.vibe.md"
printf '%s\n' 'Iterator::filter(xs, pred)' > "$tree/examples/example.vibe"
printf '%s\n' 'Iterator::iter(xs, f)' > "$tree/examples/wasm/nested.vibe"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "canonical calls and longer identifiers must pass"; }
grep -q '^canonical Iterator calls: ok (3 files)$' "$WORK/out" || { cat "$WORK/out" >&2; fail "expected ok over the 3 corpus files"; }

# A legacy call at the very end of a line, with no call parenthesis.
printf '%s\n' 'let f = Array::all' >> "$tree/book/en/chapter.vibe.md"
if gate --root "$WORK_REL/tree"; then cat "$WORK/out" >&2; fail "a legacy name at end of line must fail"; fi
grep -qF 'book/en/chapter.vibe.md:3:let f = Array::all' "$WORK/out" || { cat "$WORK/out" >&2; fail "the end-of-line call was not named"; }
printf '%s\n' 'Iterator::map(xs, f)' > "$tree/book/en/chapter.vibe.md"

# The one-argument `Array::iter` enters AsyncIter and has no Iterator spelling:
# an import, a pipe and a direct call of it are all accepted.
printf '%s\n' 'import @vibe/builtin { Array::iter, AsyncIter::collect }' '[1, 2] |> Array::iter |> AsyncIter::collect' 'AsyncIter::collect(Array::iter([1, 2]))' > "$tree/book/en/chapter.vibe.md"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "the AsyncIter entry Array::iter must pass"; }

# Nothing to scan is not clean.
mkdir -p "$WORK/empty"
if gate --root "$WORK_REL/empty"; then cat "$WORK/out" >&2; fail "a tree with no book/ and no examples/ must fail"; fi
grep -qF 'so nothing was checked' "$WORK/out" || { cat "$WORK/out" >&2; fail "the empty tree failed for the wrong reason"; }

echo "canonical Iterator calls self-test: ok"

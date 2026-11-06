#!/usr/bin/env bash
# Self-test for scripts/check_prove.sh (#3717, #2248): the gate must FAIL
# when a proved fixture stops being provable. It mutates a copy of
# fixtures/prove/ -- `add_small`'s `a + b` becomes `a - b`, so its
# `ensures: result >= a` is false -- and asserts the gate refuses it, after
# first asserting the mutation actually landed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
cli="${1:-${VIBE_STAGE2_WASM:-}}"
[ -n "$cli" ] && [ -s "$cli" ] || { echo "usage: check_prove_test.sh <stage2.wasm>" >&2; exit 2; }

work="_build/prove_selftest.$$"
rm -rf "$work"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
cp fixtures/prove/*.vibe "$work/"

# The unmutated copy passes.
if ! VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" > "$work/base.log" 2>&1; then
  echo "[prove-selftest] FAIL: the gate refused the unmutated fixtures:" >&2
  cat "$work/base.log" >&2
  exit 1
fi

sed 's/^  a + b$/  a - b/' fixtures/prove/proved.vibe > "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted an ensures that no longer holds" >&2; exit 1
fi
# A loop body that no longer keeps its invariant: `count_to` steps by 2, so
# `i <= n` can break after an iteration and the proof must stop.
sed 's/^    i += 1$/    i += 2/' fixtures/prove/proved.vibe > "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the loop mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted a loop whose invariant no longer holds" >&2; exit 1
fi
# An array read whose guarantee is weakened: `last` may now be handed an
# empty array, so `xs[length - 1]` can be out of bounds.
sed 's/requires: Array::length(xs) > 0, ensures: true/requires: Array::length(xs) >= 0, ensures: true/' fixtures/prove/proved.vibe > "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the array mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted an array read that can be out of bounds" >&2; exit 1
fi
# #3827: a word sum that no longer wraps to the minimum: `wrap_top` adds 2,
# so its `ensures: result == -2147483648` fails. (Encoding `+` on a word as
# unbounded `Int` addition is caught by the gate itself: `word_next` and
# `word_local_wraps` would prove.)
sed 's/^  Int32::to_int(x + 1)$/  Int32::to_int(x + 2)/' fixtures/prove/proved.vibe > "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the word mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted a word sum that no longer wraps" >&2; exit 1
fi
# #3719: `Array::any` is not `Array::all`: with some element non-negative,
# `first_nonneg`'s first element need not be, so its `ensures` fails.
sed 's/requires: Array::length(xs) > 0 \&\& Array::all(xs, f = (x) -> x >= 0),/requires: Array::length(xs) > 0 \&\& Array::any(xs, f = (x) -> x >= 0),/' fixtures/prove/proved.vibe > "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the quantifier mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted a requires weakened from Array::all to Array::any" >&2; exit 1
fi
# #3719: without the import, `Int::range_all` is not `@vibe/builtin`'s, so it
# is not read as a quantifier and `first_pair_sorted` stops proving. The
# other fixtures are restored first, so this mutation is the only change.
cp fixtures/prove/proved.vibe "$work/proved.vibe"
python3 -c 'import sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace("import @vibe/builtin {\n  Int::range_all, Int::range_any\n}\n", "", 1))' fixtures/prove/ranges.vibe "$work/ranges.vibe"
if cmp -s fixtures/prove/ranges.vibe "$work/ranges.vibe"; then
  echo "[prove-selftest] FAIL: the import mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted Int::range_all read as a quantifier without the @vibe/builtin import" >&2; exit 1
fi
cp fixtures/prove/ranges.vibe "$work/ranges.vibe"
# A loop that no longer breaks: `find_negative` records the index and goes
# on, so `found == -1` does not hold at the next checkpoint.
python3 -c 'import sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace("      found = i\n      break\n", "      found = i\n", 1))' fixtures/prove/proved.vibe "$work/proved.vibe"
if cmp -s fixtures/prove/proved.vibe "$work/proved.vibe"; then
  echo "[prove-selftest] FAIL: the break mutation did not apply" >&2; exit 1
fi
if VIBE_PROVE_FIXTURES="$work" bash scripts/check_prove.sh "$cli" >/dev/null 2>&1; then
  echo "[prove-selftest] FAIL: the gate accepted a loop that lost its break" >&2; exit 1
fi
echo "[prove-selftest] ok (a weakened implementation stops proving and the gate fails)"

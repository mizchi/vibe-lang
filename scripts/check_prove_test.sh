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
echo "[prove-selftest] ok (a weakened implementation stops proving and the gate fails)"

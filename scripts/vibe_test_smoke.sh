#!/usr/bin/env bash
# Smoke test for selfhost `vibe test` (scripts/vibe_test.sh): a file of passing
# tests must succeed (exit 0) and a file with a failing assert must fail.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_test_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

printf 'test "arith" {\n  assert_eq(1 + 1, 2)\n}\ntest "bool" {\n  assert(true)\n}\n' \
  > "$WORK/pass_test.vibe"
printf 'test "bad" {\n  assert_eq(1 + 1, 3)\n}\n' > "$WORK/fail_test.vibe"

if ! bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/pass_test.vibe" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: passing test file did not succeed" >&2; exit 1
fi
if bash "$ROOT_DIR/scripts/vibe_test.sh" "$WORK/fail_test.vibe" >/dev/null 2>&1; then
  echo "[vibe-test-smoke] FAIL: failing test file did not fail" >&2; exit 1
fi

echo "[vibe-test-smoke] ok (pass-file=0, fail-file!=0)"

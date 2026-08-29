#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_canonical_iterator_calls.sh"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/vibe_iterator_calls_test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/book/en" "$tmp_root/examples/wasm" "$tmp_root/bench/exec" "$tmp_root/fixtures"
printf '%s\n' 'Array::map(xs, f)' > "$tmp_root/book/en/chapter.vibe.md"
printf '%s\n' 'Array::filter(xs, pred)' > "$tmp_root/examples/example.vibe"
printf '%s\n' 'Array::iter(xs, f)' > "$tmp_root/examples/wasm/nested.vibe"
printf '%s\n' 'Array::fold(xs, 0, add)' > "$tmp_root/bench/exec/scenario.vibe"
printf '%s\n' 'Array::map(xs, f)' > "$tmp_root/fixtures/compatibility_test.vibe"

set +e
VIBE_CANONICAL_ITERATOR_ROOT="$tmp_root" bash "$CHECK" > "$tmp_root/red.out" 2>&1
red_status=$?
set -e
if [ "$red_status" -eq 0 ]; then
  echo "canonical Iterator calls self-test: expected legacy tutorial and example calls to fail" >&2
  exit 1
fi
if [ "$(grep -c 'Array::' "$tmp_root/red.out")" -ne 3 ]; then
  echo "canonical Iterator calls self-test: expected all canonical calls, including nested iter, to be found" >&2
  cat "$tmp_root/red.out" >&2
  exit 1
fi

printf '%s\n' 'Iterator::map(xs, f)' > "$tmp_root/book/en/chapter.vibe.md"
printf '%s\n' 'Iterator::filter(xs, pred)' > "$tmp_root/examples/example.vibe"
printf '%s\n' 'Iterator::iter(xs, f)' > "$tmp_root/examples/wasm/nested.vibe"
printf '%s\n' 'Iterator::fold(xs, 0, add)' > "$tmp_root/bench/exec/scenario.vibe"
VIBE_CANONICAL_ITERATOR_ROOT="$tmp_root" bash "$CHECK" > "$tmp_root/green.out"
grep -q '^canonical Iterator calls: ok$' "$tmp_root/green.out"

echo "canonical Iterator calls self-test: ok"

#!/usr/bin/env bash
# A failed multiline snapshot must show the differing lines in the report.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

out="$(mktemp)"
updated="_build/multiline_inspect_update_$$.vibe"
trap 'rm -f "$out" "$updated"' EXIT
if bash scripts/vibe_test.sh tests/integration/test_report/multiline_failure.vibe >"$out" 2>&1; then
  echo "multiline inspect: expected the fixture to fail" >&2
  exit 1
fi
if ! grep -q 'actual:   line one' "$out" ||
   ! grep -q 'expected: line one' "$out" ||
   ! grep -q '| RuntimeError: actual line' "$out" ||
   ! grep -q '| RuntimeError: expected line' "$out" ||
   ! grep -q '| wasm trap: actual detail' "$out" ||
   ! grep -q '| wasm trap: expected detail' "$out"; then
  echo "multiline inspect: report hid the differing lines" >&2
  cat "$out" >&2
  exit 1
fi
cp tests/integration/test_report/multiline_failure.vibe "$updated"
if ! bash scripts/vibe_test.sh --update "$updated" >"$out" 2>&1 ||
   grep -q 'RuntimeError: expected line' "$updated"; then
  echo "multiline inspect: snapshot updater did not repair the full value" >&2
  cat "$out" >&2
  exit 1
fi
if bash scripts/vibe_test.sh tests/integration/test_report/inspect_lookalike_trap.vibe >"$out" 2>&1 ||
   ! grep -q '       trap: RuntimeError:' "$out" ||
   grep -q 'trap: RuntimeError: fake' "$out"; then
  echo "multiline inspect: a lookalike report hid the real trap" >&2
  cat "$out" >&2
  exit 1
fi
echo "multiline inspect: snapshot lines and real traps are visible; --update repairs the snapshot"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$SCRIPT_DIR/coverage_wasm_std.sh"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

legacy_vars=(
  VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP
  VIBE_WASM_SOURCE_COVERAGE_DIR
  VIBE_WASM_SOURCE_COVERAGE_MODE
  VIBE_WASM_SOURCE_COVERAGE_NO_DCE
  VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS
  VIBE_WASM_STD_COVERAGE_STRICT
)
for name in "${legacy_vars[@]}"; do
  set +e
  env "$name=1" bash "$DRIVER" >"$tmp" 2>&1
  code=$?
  set -e
  if [ "$code" -ne 2 ] || ! grep -q "$name belongs to the retired wasm-source lane" "$tmp"; then
    cat "$tmp" >&2
    echo "coverage_wasm_std_test: $name was not rejected (exit $code)" >&2
    exit 1
  fi
done

set +e
VIBE_WASM_STD_COVERAGE_FILTER='definitely-no-such-test' bash "$DRIVER" >"$tmp" 2>&1
code=$?
set -e
if [ "$code" -ne 1 ] || ! grep -q 'no test files selected' "$tmp"; then
  cat "$tmp" >&2
  echo "coverage_wasm_std_test: empty selection did not fail (exit $code)" >&2
  exit 1
fi

echo "coverage_wasm_std_test: ok"

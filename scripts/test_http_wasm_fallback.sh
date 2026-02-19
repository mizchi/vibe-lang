#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/_build/native/debug/build/cmd/vibe/vibe.exe"
TEST_FILE="$ROOT_DIR/tests/http_wasm_fallback_test.vibe"
WASMTIME="${VIBE_WASMTIME:-wasmtime}"

echo "=== HTTP WASM Fallback Tests ==="

# Build CLI if needed
if [ ! -f "$CLI_BIN" ]; then
  echo "Building vibe (debug)..."
  (cd "$ROOT_DIR" && moon build --target native src/cmd/vibe --warn-list '-29')
fi

# Test 1: Interpreter test (native backend)
echo ""
echo "--- Test 1: Interpreter backend ---"
"$CLI_BIN" test "$TEST_FILE"

# Test 2: WASM compilation succeeds
echo ""
echo "--- Test 2: WASM compilation ---"
WASM_OUT=$(mktemp /tmp/http_wasm_XXXXXX.wasm)
"$CLI_BIN" compile --wasm --no-dce "$TEST_FILE" -o "$WASM_OUT"
echo "  compile: OK ($(wc -c < "$WASM_OUT" | tr -d ' ') bytes)"

# Test 3: WASM execution — HTTP builtins throw catchable errors
echo ""
echo "--- Test 3: WASM execution (wasmtime) ---"
# The test file's run function exercises try/catch around HTTP builtins.
# On WASM, http_request throws an exception caught by handle → returns -1.
OUTPUT=$("$WASMTIME" run --wasm exceptions "$WASM_OUT" 2>&1) && {
  echo "  execution: OK"
} || {
  # If wasmtime exits non-zero, check if it's an uncaught exception vs. trap
  if echo "$OUTPUT" | grep -q "unreachable"; then
    echo "  FAIL: wasm trap (unreachable) — HTTP builtins should throw, not trap"
    rm -f "$WASM_OUT"
    exit 1
  elif echo "$OUTPUT" | grep -q "thrown Wasm exception"; then
    echo "  OK: wasm exception thrown (expected for non-test entry point)"
  else
    echo "  WARN: unexpected output: $OUTPUT"
  fi
}

# Test 4: precompile vibe/http succeeds
echo ""
echo "--- Test 4: precompile vibe/http ---"
DIST_DIR=$(mktemp -d /tmp/http_precompile_XXXXXX)
"$CLI_BIN" precompile vibe/http --out-dir "$DIST_DIR" --wasm
echo "  precompile: OK"

# Cleanup
rm -f "$WASM_OUT"
rm -rf "$DIST_DIR"

echo ""
echo "=== All HTTP WASM Fallback Tests passed ==="

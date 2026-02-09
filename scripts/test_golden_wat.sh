#!/bin/bash
# Golden test for WAT output
# Usage: ./scripts/test_golden_wat.sh [--update]

set -e

GOLDEN_DIR="examples/golden_wat"
TEMP_DIR="/tmp/golden_wat_test"
UPDATE_MODE=false

if [ "$1" == "--update" ]; then
  UPDATE_MODE=true
fi

mkdir -p "$TEMP_DIR"

failed=0
passed=0

for xsh_file in "$GOLDEN_DIR"/*.xsh; do
  name=$(basename "$xsh_file" .xsh)
  expected_wat="$GOLDEN_DIR/${name}.wat"
  actual_wasm="$TEMP_DIR/${name}.wasm"
  actual_wat="$TEMP_DIR/${name}.wat"

  # Compile to WASM
  if ! moon run src/cmd/xsh/main.mbt --target native -- compile --wasm "$xsh_file" -o "$actual_wasm" 2>/dev/null; then
    echo "FAIL: $name (compilation error)"
    failed=$((failed + 1))
    continue
  fi

  # Convert to WAT
  wasm-tools print "$actual_wasm" > "$actual_wat"

  if [ "$UPDATE_MODE" == "true" ]; then
    cp "$actual_wat" "$expected_wat"
    echo "UPDATED: $name"
    passed=$((passed + 1))
  else
    # Compare
    if diff -q "$expected_wat" "$actual_wat" > /dev/null 2>&1; then
      echo "PASS: $name"
      passed=$((passed + 1))
    else
      echo "FAIL: $name (output differs)"
      echo "  Expected: $expected_wat"
      echo "  Actual:   $actual_wat"
      echo "  Diff:"
      diff "$expected_wat" "$actual_wat" | head -20
      failed=$((failed + 1))
    fi
  fi
done

echo ""
echo "Summary: $passed passed, $failed failed"

if [ $failed -gt 0 ]; then
  exit 1
fi

#!/bin/bash
# Golden test for WAT output
# Usage: ./scripts/test_golden_wat.sh [--update]

set -euo pipefail

GOLDEN_DIR="examples/golden_wat"
TEMP_DIR="/tmp/golden_wat_test"
UPDATE_MODE=false
VIBE_BIN="${VIBE_BIN:-_build/native/debug/build/cmd/vibe/vibe.exe}"
USE_WITE="${VIBE_GOLDEN_USE_WITE:-1}"
OPT_LEVEL="${VIBE_GOLDEN_OPT_LEVEL:-}"

if [ "${1:-}" == "--update" ]; then
  UPDATE_MODE=true
elif [ "${1:-}" != "" ]; then
  echo "unknown arg: $1" >&2
  echo "usage: ./scripts/test_golden_wat.sh [--update]" >&2
  exit 1
fi

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native src/cmd/vibe --warn-list '-29'
fi
if [ ! -x "$VIBE_BIN" ]; then
  echo "vibe cli binary not found: $VIBE_BIN" >&2
  exit 1
fi

mkdir -p "$TEMP_DIR"
mkdir -p "$TEMP_DIR/src"

failed=0
passed=0

for vibe_file in "$GOLDEN_DIR"/*.vibe; do
  name=$(basename "$vibe_file" .vibe)
  expected_wat="$GOLDEN_DIR/${name}.wat"
  temp_vibe="$TEMP_DIR/src/${name}.vibe"
  actual_wasm="$TEMP_DIR/${name}.wasm"
  actual_wat="$TEMP_DIR/${name}.wat"

  cp "$vibe_file" "$temp_vibe"

  compile_args=(compile --wasm)
  if [ "$USE_WITE" = "1" ]; then
    if [ -n "$OPT_LEVEL" ]; then
      compile_args+=("$OPT_LEVEL")
    else
      compile_args+=(--wite)
    fi
  fi
  compile_args+=("$temp_vibe" -o "$actual_wasm")

  # Compile to WASM
  if ! "$VIBE_BIN" "${compile_args[@]}" 2>/dev/null; then
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

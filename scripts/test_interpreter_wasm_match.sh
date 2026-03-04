#!/bin/bash
# Test that interpreter and WASM produce the same output for pattern matching
# This verifies codegen correctness by comparing evaluation results

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEMP_DIR="/tmp/interpreter_wasm_match"
WASMTIME_BIN="${WASMTIME_BIN:-$("$PROJECT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$PROJECT_DIR/scripts/wasmtime_run.sh"

mkdir -p "$TEMP_DIR"

# Use pre-built VIBE_BIN if set, otherwise fall back to moon run
if [ -n "${VIBE_BIN:-}" ] && [ -x "$VIBE_BIN" ]; then
  VIBE="$VIBE_BIN"
else
  VIBE="moon run $PROJECT_DIR/src/cmd/vibe/main.mbt --target native --"
fi

failed=0
passed=0

# Test cases: each prints a result value
test_cases=(
  # Tuple patterns
  'let (a, b) = (1, 2); a + b'
  'let (a, (b, c)) = (1, (2, 3)); a + b + c'
  'match (1, 2) { (a, b) => a * b, _ => 0 }'

  # Record patterns
  'let record { x: a, y: b } = record { x: 10, y: 20 }; a + b'
  'match record { a: 1, b: 2 } { record { a: x, b: y } => x + y, _ => 0 }'

  # Ctor patterns (Option)
  'match Some(42) { Some(x) => x, _ => 0 }'
  'match None { Some(x) => x, _ => 99 }'
  'let Some(x) = Some(100); x'

  # Or patterns
  'match 2 { 1 | 2 | 3 => 100, _ => 0 }'
  'match 5 { 1 | 2 | 3 => 100, _ => 0 }'

  # Int patterns
  'match 42 { 0 => 0, 42 => 1, _ => 2 }'
  'match 99 { 0 => 0, 42 => 1, _ => 2 }'

  # Bool patterns
  'match true { true => 1, _ => 0 }'
  'match false { true => 1, _ => 0 }'

  # Float patterns
  'match 1.5f { 1.5f => 1, _ => 0 }'
  'match 2.0f { 1.5f => 1, _ => 0 }'

  # Double patterns
  'match 1.5 { 1.5 => 1, _ => 0 }'
  'match 2.0 { 1.5 => 1, _ => 0 }'

  # Nested patterns
  'match Some((1, 2)) { Some((a, b)) => a + b, _ => 0 }'
  'match (Some(10), None) { (Some(a), None) => a, _ => 0 }'

  # Wildcard in patterns
  'let (a, _, c) = (1, 2, 3); a + c'
  'let record { x: a, y: _ } = record { x: 10, y: 20 }; a'

  # For-in with mutable accumulation
  'let mut total = 0; for x in [1, 2, 3, 4, 5] { total = total + x }; total'
  'let mut sum = 0; for x in [10, 20, 30] { sum = sum + x; x }; sum'

  # String builtins
  'string_length("hello")'
  'if string_contains("hello world", "world") { 1 } else { 0 }'
  'if string_contains("hello", "xyz") { 1 } else { 0 }'
  'if string_starts_with("hello", "hel") { 1 } else { 0 }'
  'if string_ends_with("hello", "llo") { 1 } else { 0 }'
  'string_index_of("hello world", "world")'
  'string_index_of("hello", "xyz")'
  'string_last_index_of("abcabc", "abc")'
  'string_char_code_at("A", 0)'
  'string_count("abcabc", "abc")'
  'string_count("aaaa", "aa")'
  'string_length(string_trim("  hi  "))'
  'string_length(string_trim_start("  hi  "))'
  'string_length(string_trim_end("  hi  "))'
  'string_length(string_concat("hello", " world"))'
  'string_length(string_substring("hello world", 0, 5))'
  'string_char_code_at(string_to_upper("abc"), 0)'
  'string_char_code_at(string_to_lower("ABC"), 0)'
)

echo "Testing interpreter vs WASM output..."
echo ""

for expr in "${test_cases[@]}"; do
  # Create test file
  echo "$expr" > "$TEMP_DIR/test.vibe"

  # Run interpreter via eval and extract numeric value
  interp_output=$($VIBE eval "$expr" 2>/dev/null | grep "^last: " | sed 's/last: //')
  interp_result="$interp_output"

  # Compile and run WASM
  if $VIBE compile --wasm "$TEMP_DIR/test.vibe" -o "$TEMP_DIR/test.wasm" 2>/dev/null; then
    # Run with --invoke to get return value, untag integer (divide by 4)
    wasm_tagged=$(WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke run "$TEMP_DIR/test.wasm" 2>/dev/null | grep -v "^warning")
    if [ -n "$wasm_tagged" ]; then
      # Untag: shift right 2 bits (divide by 4)
      wasm_result=$((wasm_tagged >> 2))
    else
      wasm_result="<no output>"
    fi
  else
    wasm_result="<compile error>"
  fi

  # Compare
  if [ "$interp_result" = "$wasm_result" ]; then
    echo "PASS: $expr => $interp_result"
    passed=$((passed + 1))
  else
    echo "FAIL: $expr"
    echo "  Interpreter: $interp_result"
    echo "  WASM:        $wasm_result (tagged: $wasm_tagged)"
    failed=$((failed + 1))
  fi
done

echo ""
echo "Summary: $passed passed, $failed failed"

if [ $failed -gt 0 ]; then
  exit 1
fi

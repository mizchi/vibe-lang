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

  # String equality operator (==)
  'if "hello" == "hello" { 1 } else { 0 }'
  'if "hello" == "world" { 1 } else { 0 }'
  'if "" == "" { 1 } else { 0 }'

  # String split
  'array_length(string_split("a,b,c", ","))'
  'array_length(string_split("hello", ","))'
  'array_length(string_split("a::b::c", "::"))'
  'array_length(string_split("abc", ""))'

  # String replace
  'string_length(string_replace("hello world", "world", "vibe"))'
  'string_length(string_replace("aaa", "a", "bb"))'
  'string_length(string_replace_all("aaa", "a", "bb"))'
  'if string_equals(string_replace("foo bar foo", "foo", "baz"), "baz bar foo") { 1 } else { 0 }'
  'if string_equals(string_replace_all("foo bar foo", "foo", "baz"), "baz bar baz") { 1 } else { 0 }'

  # Break and continue
  'let mut sum = 0; let mut i = 0; while i < 10 { i = i + 1; if i == 5 { break }; sum = sum + i }; sum'
  'let mut sum = 0; let mut i = 0; while i < 10 { i = i + 1; if i % 2 == 0 { continue }; sum = sum + i }; sum'
  'let mut sum = 0; let mut i = 0; while i < 100 { i = i + 1; if i % 3 == 0 { continue }; if i > 10 { break }; sum = sum + i }; sum'

  # Closures and higher-order functions
  'let f = (x: Int) -> Int { x * 2 }; f(5)'
  'let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }; apply((x: Int) -> Int { x + 1 }, 5)'
  'let make_adder = (n: Int) -> (Int) -> Int { (x: Int) -> Int { x + n } }; let add5 = make_adder(5); add5(10)'
  # Note: mutable capture through closures has interpreter limitation (returns 0 instead of 3)

  # Recursive functions
  'let rec fact = (n: Int) -> Int { if n <= 1 { 1 } else { n * fact(n - 1) } }; fact(5)'
  'let rec fib = (n: Int) -> Int { if n <= 1 { n } else { fib(n - 1) + fib(n - 2) } }; fib(10)'

  # Array operations
  'array_length([1, 2, 3, 4, 5])'
  'let arr = [10, 20, 30]; arr[1]'
  'array_length(array_concat([1, 2], [3, 4]))'
  'array_length(array_slice([1, 2, 3, 4, 5], 1, 3))'

  # Pipe operator
  'let double = (x: Int) -> Int { x * 2 }; 5 |> double'
  'let inc = (x: Int) -> Int { x + 1 }; let double = (x: Int) -> Int { x * 2 }; 3 |> inc |> double'

  # Block expressions
  'let x = { let a = 10; let b = 20; a + b }; x'
  'let y = { let mut sum = 0; for i in [1, 2, 3] { sum = sum + i }; sum }; y'

  # Complex combinations
  'let arr = [1, 2, 3, 4, 5]; let mut sum = 0; for x in arr { if x % 2 == 1 { sum = sum + x * x } }; sum'
  'match (Some(10), Some(20)) { (Some(a), Some(b)) => a + b, _ => 0 }'
  'let rec sum_to = (n: Int) -> Int { if n <= 0 { 0 } else { n + sum_to(n - 1) } }; sum_to(10)'

  # Bitwise operations
  '7 & 3'
  '5 | 3'
  '6 ^ 3'
  '1 << 4'
  '32 >> 3'

  # Boolean operations
  'if true && true { 1 } else { 0 }'
  'if true && false { 1 } else { 0 }'
  'if false || true { 1 } else { 0 }'
  'if false || false { 1 } else { 0 }'

  # Nested closures
  'let outer = (x: Int) -> (Int) -> Int { let y = x + 1; (z: Int) -> Int { y + z } }; outer(10)(5)'
  'let compose = (f: (Int) -> Int, g: (Int) -> Int) -> (Int) -> Int { (x: Int) -> Int { f(g(x)) } }; let add1 = (x: Int) -> Int { x + 1 }; let mul2 = (x: Int) -> Int { x * 2 }; compose(add1, mul2)(5)'
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

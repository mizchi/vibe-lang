#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WASMTIME_RUN="$SCRIPT_DIR/wasmtime_run.sh"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
TMP_DIR="$(mktemp -d /tmp/vibe_handle_exception_wasm_match.XXXXXX)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [ ! -x "$VIBE_BIN" ]; then
  moon build --target native --release src/cmd/vibe --warn-list '-29' >/dev/null
fi

if [ ! -x "$WASMTIME_RUN" ]; then
  echo "wasmtime runner not found: $WASMTIME_RUN" >&2
  exit 1
fi

passed=0
failed=0

run_case() {
  local name="$1"
  local source="$2"
  local expected="$3"
  local file="$TMP_DIR/${name}.vibe"
  local wasm="$TMP_DIR/${name}.wasm"

  printf "%s\n" "$source" > "$file"

  if ! "$VIBE_BIN" compile --wasm --debug-errors "$file" -o "$wasm" >/dev/null 2>&1; then
    echo "FAIL: $name (wasm compile failed)"
    failed=$((failed + 1))
    return
  fi

  local wasm_tagged
  wasm_tagged="$(VIBE_WASMTIME_WASM_FLAGS='exceptions=y' "$WASMTIME_RUN" --invoke _start "$wasm" 2>/dev/null | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
  if [ -z "$wasm_tagged" ]; then
    echo "FAIL: $name (wasmtime output missing)"
    failed=$((failed + 1))
    return
  fi

  local wasm_result
  wasm_result=$((wasm_tagged >> 2))

  if [ "$expected" = "$wasm_result" ]; then
    echo "PASS: $name => $wasm_result"
    passed=$((passed + 1))
  else {
    echo "FAIL: $name"
    echo "  expected: $expected"
    echo "  wasm:     $wasm_result (tagged: $wasm_tagged)"
    failed=$((failed + 1))
  }
  fi
}

case_handle_passthrough=$(cat <<'VIBE'
let main = () -> Int {
  handle {
    42
  } {
    _ => 0
  }
}

main()
VIBE
)

case_throw_const=$(cat <<'VIBE'
let fail = () -> Int with { Error } {
  throw("boom")
}

let main = () -> Int {
  handle {
    fail()
  } {
    _ => 99
  }
}

main()
VIBE
)

case_throw_bind=$(cat <<'VIBE'
let fail = () -> Int with { Error } {
  throw("boom")
}

let main = () -> Int {
  handle {
    fail()
  } {
    Error(msg) => String::length(msg)
  }
}

main()
VIBE
)

case_nested_throw=$(cat <<'VIBE'
let fail = () -> Int with { Error } {
  throw("inner")
}

let main = () -> Int {
  handle {
    handle {
      fail()
    } {
      _ => throw("outer")
    }
  } {
    Error(msg) => String::length(msg)
  }
}

main()
VIBE
)

# Expected values: handle_passthrough=42, throw_const=99,
# throw_bind=4 (length of "boom"), nested_throw=5 (length of "outer")
run_case "handle_passthrough" "$case_handle_passthrough" "42"
run_case "handle_throw_const" "$case_throw_const" "99"
run_case "handle_throw_bind" "$case_throw_bind" "4"
run_case "handle_nested_throw" "$case_nested_throw" "5"

echo "Summary: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi

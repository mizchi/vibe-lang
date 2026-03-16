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
  local file="$TMP_DIR/${name}.vibe"
  local wasm="$TMP_DIR/${name}.wasm"
  local db="$TMP_DIR/${name}.db"

  printf "%s\n" "$source" > "$file"

  local interp_result
  interp_result="$($VIBE_BIN eval --db "$db" --include "$file" "main()" 2>/dev/null | sed -n 's/^last: //p' | head -n 1)"
  if [ -z "$interp_result" ]; then
    echo "FAIL: $name (interpreter result missing)"
    failed=$((failed + 1))
    return
  fi

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

  if [ "$interp_result" = "$wasm_result" ]; then
    echo "PASS: $name => $interp_result"
    passed=$((passed + 1))
  else
    echo "FAIL: $name"
    echo "  interpreter: $interp_result"
    echo "  wasm:        $wasm_result (tagged: $wasm_tagged)"
    failed=$((failed + 1))
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

let main = () -> Int with { Error } {
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

let main = () -> Int with { Error } {
  handle {
    fail()
  } {
    Error(msg) => string_length(msg)
  }
}

main()
VIBE
)

case_nested_throw=$(cat <<'VIBE'
let fail = () -> Int with { Error } {
  throw("inner")
}

let main = () -> Int with { Error } {
  handle {
    handle {
      fail()
    } {
      _ => throw("outer")
    }
  } {
    Error(msg) => string_length(msg)
  }
}

main()
VIBE
)

run_case "handle_passthrough" "$case_handle_passthrough"
run_case "handle_throw_const" "$case_throw_const"
run_case "handle_throw_bind" "$case_throw_bind"
run_case "handle_nested_throw" "$case_nested_throw"

echo "Summary: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi

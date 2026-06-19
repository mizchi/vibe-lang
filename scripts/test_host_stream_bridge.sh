#!/usr/bin/env bash
set -euo pipefail

# M2c-3 host-stream bridge gate (docs/spec/wasi-p3-async.md §3.3).
#
# Proves a vibe handler can consume a HOST-provided byte stream incrementally:
# the node runner feeds bytes through the WASI 0.2 input-stream
# (input-stream.blocking-read) via VIBE_STDIN_BYTES, and vibe/io's
# `print_stdin_sum` drains it with a read_char() loop and prints the byte sum.
# This is the testable stand-in for the WASI 0.3 stream<u8> HTTP body (where
# wasmtime is the producer); see §3.3 for why an intra-wasm producer can't
# work.
#
# Skips cleanly when node is unavailable.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/_build/bench/host_stream_bridge"
SRC="$PROJECT_ROOT/vibe/io/stdin_stream_main.vibe"
WASM="$OUT_DIR/stdin_main.wasm"
RUNNER="$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "[host-stream-gate] SKIP: node not found"; exit 0
fi
if [ ! -f "$RUNNER" ]; then
  echo "[host-stream-gate] SKIP: wasm host runner not found"; exit 0
fi

mkdir -p "$OUT_DIR"

HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
if [ -x "$HOST_VIBE_EXE" ]; then
  COMPILE=("$HOST_VIBE_EXE" compile --wasm)
else
  COMPILE=(moon run --target native src/cmd/vibe -- compile --wasm)
fi

echo "[host-stream-gate] compiling $SRC"
"${COMPILE[@]}" "$SRC" -o "$WASM" >/dev/null

# Feed "ABC" (65+66+67 = 198) and a second body to prove it is the feed, not a
# constant, that drives the result.
check() {
  local feed="$1" expected="$2"
  local out
  out="$(VIBE_STDIN_BYTES="$feed" bash "$RUNNER" --invoke print_stdin_sum "$WASM" 0 2>/dev/null \
    | grep -E '^[0-9]+$' | head -n1 || true)"
  if [ "$out" = "$expected" ]; then
    echo "[host-stream-gate] PASS: feed='$feed' -> sum $out"
  else
    echo "[host-stream-gate] FAIL: feed='$feed' -> '$out' (expected $expected)" >&2
    exit 1
  fi
}

check "ABC" 198   # 65 + 66 + 67
check "AA"  130   # 65 + 65
check ""    0     # empty body -> EOF immediately

# read_all round-trip: feed a body and assert echo_stdin returns it verbatim.
check_echo() {
  local feed="$1"
  local out
  out="$(VIBE_STDIN_BYTES="$feed" bash "$RUNNER" --invoke echo_stdin "$WASM" 0 2>/dev/null \
    | head -n1 || true)"
  if [ "$out" = "$feed" ]; then
    echo "[host-stream-gate] PASS: echo '$feed'"
  else
    echo "[host-stream-gate] FAIL: echo '$feed' -> '$out'" >&2
    exit 1
  fi
}

check_echo "hello world"
check_echo "vibe"

echo "[host-stream-gate] done"

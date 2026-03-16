#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
SCRIPT_PATH="$ROOT_DIR/bench/bench_simple.vibe"
WASM_OUT="$ROOT_DIR/target/bench/vibe_bench.wasm"
WASMTIME_BIN="${WASMTIME_BIN:-$("$ROOT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$ROOT_DIR/scripts/wasmtime_run.sh"

mkdir -p "$ROOT_DIR/target/bench"

moon build --target native --release src/cmd/vibe

"$CLI_BIN" compile --wasm -o "$WASM_OUT" "$SCRIPT_PATH"

INTERP_CMD="\"$CLI_BIN\" run \"$SCRIPT_PATH\" >/dev/null"
WASM_CMD="WASMTIME_BIN=\"$WASMTIME_BIN\" \"$WASMTIME_RUN\" --invoke _start \"$WASM_OUT\" >/dev/null"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 3 "$INTERP_CMD" "$WASM_CMD"
else
  echo "hyperfine not found; using /usr/bin/time (10 runs each)"
  echo "[interp]"
  for _ in $(seq 1 10); do
    /usr/bin/time -p bash -c "$INTERP_CMD"
  done
  echo "[wasmtime]"
  for _ in $(seq 1 10); do
    /usr/bin/time -p bash -c "$WASM_CMD"
  done
fi

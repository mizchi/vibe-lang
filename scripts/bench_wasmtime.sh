#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI_BIN="$VIBE_CLI_BIN"
SCRIPT_PATH="$ROOT_DIR/bench/bench_simple.vibe"
WASM_OUT="$ROOT_DIR/target/bench/vibe_bench.wasm"
WASMTIME_BIN="${WASMTIME_BIN:-$("$ROOT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$ROOT_DIR/scripts/wasmtime_run.sh"

mkdir -p "$ROOT_DIR/target/bench"



"$CLI_BIN" compile --wasm -o "$WASM_OUT" "$SCRIPT_PATH"

if command -v hyperfine >/dev/null 2>&1; then
  hyperfine --warmup 3 "WASMTIME_BIN=\"$WASMTIME_BIN\" \"$WASMTIME_RUN\" --invoke _start \"$WASM_OUT\" >/dev/null"
else
  echo "hyperfine not found; using /usr/bin/time (10 runs)"
  for _ in $(seq 1 10); do
    /usr/bin/time -p env WASMTIME_BIN="$WASMTIME_BIN" "$WASMTIME_RUN" --invoke _start "$WASM_OUT" >/dev/null
  done
fi

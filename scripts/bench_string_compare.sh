#!/usr/bin/env bash
set -euo pipefail

# Kill child processes on interrupt to prevent orphans
trap 'trap - EXIT; kill -- -$$ 2>/dev/null || true' INT TERM

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
SCRIPT_PATH="${1:-$ROOT_DIR/bench/bench_string.vibe}"
NAME="$(basename "$SCRIPT_PATH" .vibe)"
JS_WASM_OUT="$ROOT_DIR/target/bench/${NAME}_js_string.wasm"
GC_WASM_OUT="$ROOT_DIR/target/bench/${NAME}_gc.wasm"
WASMTIME_BIN="${WASMTIME_BIN:-$("$ROOT_DIR/scripts/wasmtime_bin.sh")}"
WASMTIME_RUN="$ROOT_DIR/scripts/wasmtime_run.sh"

mkdir -p "$ROOT_DIR/target/bench"

moon build --target native --release src/cmd/vibe

"$CLI_BIN" compile --wasm-js-string -o "$JS_WASM_OUT" "$SCRIPT_PATH"
if ! "$CLI_BIN" compile --wasm-gc -o "$GC_WASM_OUT" "$SCRIPT_PATH"; then
  echo "failed to compile --wasm-gc. wasm-gc string lowering may be incomplete."
  exit 1
fi

JS_CMD="node $ROOT_DIR/scripts/run_wasm_js_string_file.mjs $JS_WASM_OUT >/dev/null"
GC_CMD="WASMTIME_BIN=\"$WASMTIME_BIN\" \"$WASMTIME_RUN\" -W gc --invoke run \"$GC_WASM_OUT\" >/dev/null"
ONLY_GC=0

if ! bash -c "$JS_CMD"; then
  echo "js-string run failed; running GC only"
  ONLY_GC=1
fi

if command -v hyperfine >/dev/null 2>&1; then
  if [ "$ONLY_GC" -eq 1 ]; then
    hyperfine --warmup 3 "$GC_CMD"
  else
    hyperfine --warmup 3 "$JS_CMD" "$GC_CMD"
  fi
else
  echo "hyperfine not found; using /usr/bin/time (10 runs each)"
  if [ "$ONLY_GC" -eq 1 ]; then
    echo "[gc]"
    for _ in $(seq 1 10); do
      /usr/bin/time -p bash -c "$GC_CMD"
    done
    exit 0
  fi
  echo "[js-string]"
  for _ in $(seq 1 10); do
    /usr/bin/time -p bash -c "$JS_CMD"
  done
  echo "[gc]"
  for _ in $(seq 1 10); do
    /usr/bin/time -p bash -c "$GC_CMD"
  done
fi

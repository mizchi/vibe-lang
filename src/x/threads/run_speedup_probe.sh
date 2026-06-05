#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WAT_PATH="$SCRIPT_DIR/wasi_threads_speedup_bench.wat"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_wasi_threads_speedup.XXXXXX")"
WASM_PATH="$TMP_DIR/wasi_threads_speedup_bench.wasm"
REPORT_PATH="$TMP_DIR/hyperfine.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

: "${VIBE_USE_WASMTIME_PREBUILT:=1}"
export VIBE_USE_WASMTIME_PREBUILT

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "wasm-tools is required. install: cargo install wasm-tools" >&2
  exit 1
fi

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine is required for speedup verification. install: cargo install hyperfine" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to summarize hyperfine results" >&2
  exit 1
fi

if [ ! -f "$WAT_PATH" ]; then
  echo "speedup bench wat not found: $WAT_PATH" >&2
  exit 1
fi

wasm-tools parse "$WAT_PATH" -o "$WASM_PATH"

: "${VIBE_WASMTIME_WASM_FLAGS:=threads=y shared-memory=y}"
: "${VIBE_WASMTIME_WASI_FLAGS:=threads=y}"
: "${VIBE_THREADS_SPEEDUP_RUNS:=5}"
: "${VIBE_THREADS_SPEEDUP_WARMUP:=1}"
: "${VIBE_THREADS_SPEEDUP_MIN:=1.10}"

WASMTIME_RESOLVED="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh")"

echo "WAT: $WAT_PATH"
echo "WASM: $WASM_PATH"
echo "wasmtime: $("$WASMTIME_RESOLVED" --version)"
echo "VIBE_WASMTIME_WASM_FLAGS=$VIBE_WASMTIME_WASM_FLAGS"
echo "VIBE_WASMTIME_WASI_FLAGS=$VIBE_WASMTIME_WASI_FLAGS"
echo "VIBE_THREADS_SPEEDUP_MIN=$VIBE_THREADS_SPEEDUP_MIN"

# Correctness gate: `_start` runs serial and parallel once and compares their checksums.
VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" run "$WASM_PATH" >/dev/null

printf -v RUNNER_Q "%q" "$PROJECT_ROOT/scripts/wasmtime_run.sh"
printf -v WASM_Q "%q" "$WASM_PATH"
printf -v WASM_FLAGS_Q "%q" "$VIBE_WASMTIME_WASM_FLAGS"
printf -v WASI_FLAGS_Q "%q" "$VIBE_WASMTIME_WASI_FLAGS"

COMMON_ENV="VIBE_WASMTIME_WASM_FLAGS=$WASM_FLAGS_Q VIBE_WASMTIME_WASI_FLAGS=$WASI_FLAGS_Q"
SERIAL_CMD="$COMMON_ENV $RUNNER_Q run --invoke serial $WASM_Q >/dev/null"
PARALLEL_CMD="$COMMON_ENV $RUNNER_Q run --invoke parallel $WASM_Q >/dev/null"

hyperfine \
  --warmup "$VIBE_THREADS_SPEEDUP_WARMUP" \
  --runs "$VIBE_THREADS_SPEEDUP_RUNS" \
  --export-json "$REPORT_PATH" \
  --command-name serial \
  --command-name parallel \
  "$SERIAL_CMD" \
  "$PARALLEL_CMD"

node - "$REPORT_PATH" "$VIBE_THREADS_SPEEDUP_MIN" <<'NODE'
const fs = require("node:fs");

const reportPath = process.argv[2];
const minSpeedup = Number(process.argv[3]);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const serial = report.results[0];
const parallel = report.results[1];
const speedup = serial.mean / parallel.mean;

console.log(
  `speedup: ${speedup.toFixed(2)}x ` +
    `(serial=${serial.mean.toFixed(3)}s, parallel=${parallel.mean.toFixed(3)}s)`,
);

if (!Number.isFinite(speedup) || speedup < minSpeedup) {
  console.error(
    `expected at least ${minSpeedup.toFixed(2)}x speedup, got ${speedup.toFixed(2)}x`,
  );
  process.exit(1);
}
NODE

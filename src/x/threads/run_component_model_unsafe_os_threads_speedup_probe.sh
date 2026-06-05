#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_component_unsafe_os_threads_speedup.XXXXXX")"
SERIAL_WAST="$TMP_DIR/component_model_unsafe_os_threads_vibe_abi_speedup_serial.generated.wast"
PARALLEL_WAST="$TMP_DIR/component_model_unsafe_os_threads_vibe_abi_speedup_parallel.generated.wast"
REPORT_PATH="$TMP_DIR/hyperfine.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

: "${VIBE_USE_WASMTIME_PREBUILT:=1}"
export VIBE_USE_WASMTIME_PREBUILT

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine is required for speedup verification. install: cargo install hyperfine" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to summarize hyperfine results" >&2
  exit 1
fi

(
  cd "$PROJECT_ROOT"
  moon run --target native src/cmd/thread_probe_codegen -- \
    speedup-serial \
    --out "$SERIAL_WAST"
  moon run --target native src/cmd/thread_probe_codegen -- \
    speedup-parallel \
    --out "$PARALLEL_WAST"
)

: "${VIBE_WASMTIME_WASM_FLAGS:=threads=y component-model=y component-model-async=y component-model-threading=y gc=y function-references=y shared-everything-threads=y}"
: "${VIBE_WASMTIME_WASI_FLAGS:=}"
: "${WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN:=1}"
: "${VIBE_THREADS_SPEEDUP_RUNS:=5}"
: "${VIBE_THREADS_SPEEDUP_WARMUP:=1}"
: "${VIBE_THREADS_SPEEDUP_MIN:=1.10}"
export WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN

WASMTIME_RESOLVED="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh")"

echo "GENERATED_SERIAL_WAST: $SERIAL_WAST"
echo "GENERATED_PARALLEL_WAST: $PARALLEL_WAST"
echo "wasmtime: $("$WASMTIME_RESOLVED" --version)"
echo "WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=$WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN"
echo "VIBE_WASMTIME_WASM_FLAGS=$VIBE_WASMTIME_WASM_FLAGS"
echo "VIBE_WASMTIME_WASI_FLAGS=$VIBE_WASMTIME_WASI_FLAGS"
echo "VIBE_THREADS_SPEEDUP_MIN=$VIBE_THREADS_SPEEDUP_MIN"

# Correctness gates. Each WAST asserts the shared-slot checksum.
VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$SERIAL_WAST" >/dev/null

VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$PARALLEL_WAST" >/dev/null

printf -v RUNNER_Q "%q" "$PROJECT_ROOT/scripts/wasmtime_run.sh"
printf -v SERIAL_WAST_Q "%q" "$SERIAL_WAST"
printf -v PARALLEL_WAST_Q "%q" "$PARALLEL_WAST"
printf -v WASM_FLAGS_Q "%q" "$VIBE_WASMTIME_WASM_FLAGS"
printf -v WASI_FLAGS_Q "%q" "$VIBE_WASMTIME_WASI_FLAGS"
printf -v UNSAFE_OS_SPAWN_Q "%q" "$WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN"

COMMON_ENV="WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=$UNSAFE_OS_SPAWN_Q VIBE_WASMTIME_WASM_FLAGS=$WASM_FLAGS_Q VIBE_WASMTIME_WASI_FLAGS=$WASI_FLAGS_Q"
SERIAL_CMD="$COMMON_ENV $RUNNER_Q wast $SERIAL_WAST_Q >/dev/null"
PARALLEL_CMD="$COMMON_ENV $RUNNER_Q wast $PARALLEL_WAST_Q >/dev/null"

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

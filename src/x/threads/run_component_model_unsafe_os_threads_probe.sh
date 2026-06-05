#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe_component_unsafe_os_threads_probe.XXXXXX")"
WAST_PATH="$TMP_DIR/component_model_unsafe_os_threads_vibe_abi_probe.generated.wast"
CHANNEL_WAST_PATH="$TMP_DIR/component_model_unsafe_os_threads_channel_abi_probe.generated.wast"
CHANNEL_SPAWN_WAST_PATH="$TMP_DIR/component_model_unsafe_os_threads_channel_spawn_abi_probe.generated.wast"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

: "${VIBE_USE_WASMTIME_PREBUILT:=1}"
export VIBE_USE_WASMTIME_PREBUILT

(
  cd "$PROJECT_ROOT"
  moon run --target native src/cmd/thread_probe_codegen -- \
    vibe-abi \
    --out "$WAST_PATH"
  moon run --target native src/cmd/thread_probe_codegen -- \
    channel-abi \
    --out "$CHANNEL_WAST_PATH"
  moon run --target native src/cmd/thread_probe_codegen -- \
    channel-spawn-abi \
    --out "$CHANNEL_SPAWN_WAST_PATH"
)

: "${VIBE_WASMTIME_WASM_FLAGS:=threads=y component-model=y component-model-async=y component-model-threading=y gc=y function-references=y shared-everything-threads=y}"
: "${VIBE_WASMTIME_WASI_FLAGS:=}"
: "${WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN:=1}"
export WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN

WASMTIME_RESOLVED="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh")"

echo "GENERATED_WAST: $WAST_PATH"
echo "GENERATED_CHANNEL_WAST: $CHANNEL_WAST_PATH"
echo "GENERATED_CHANNEL_SPAWN_WAST: $CHANNEL_SPAWN_WAST_PATH"
echo "wasmtime: $("$WASMTIME_RESOLVED" --version)"
echo "WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=$WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN"
echo "VIBE_WASMTIME_WASM_FLAGS=$VIBE_WASMTIME_WASM_FLAGS"
echo "VIBE_WASMTIME_WASI_FLAGS=$VIBE_WASMTIME_WASI_FLAGS"

VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$WAST_PATH"

VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$CHANNEL_WAST_PATH"

VIBE_WASMTIME_WASM_FLAGS="$VIBE_WASMTIME_WASM_FLAGS" \
VIBE_WASMTIME_WASI_FLAGS="$VIBE_WASMTIME_WASI_FLAGS" \
"$PROJECT_ROOT/scripts/wasmtime_run.sh" wast "$CHANNEL_SPAWN_WAST_PATH"

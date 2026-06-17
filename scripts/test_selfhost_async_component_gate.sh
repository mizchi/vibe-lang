#!/usr/bin/env bash
set -euo pipefail

# WASI 0.3 async component gate (docs/spec/wasi-p3-async.md, M1b/M1b-2).
#
# Codifies the end-to-end async vertical: a freshly built stage1 selfhost
# compiler compiles an async entry (`run : () -> Int with { Async }`) into an
# async-lifted WASM component, which wasmtime 45 then runs to a known result.
#
#   stage0 (MoonBit host) compiles vibe/compiler/index.vibe -> index_stage1.wasm
#   stage1 compiles the async input via selfbuild_cli_args_entry -> out.wasm
#   out.wasm must be a COMPONENT (magic 0d 00 01 00), validate, and return 42
#
# Also asserts the non-async control (`run : () -> Int`) stays a plain core
# module — i.e. the async wrapping does not leak into ordinary builds.
#
# Skips cleanly when wasmtime / wasm-tools / node are unavailable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_async_component"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_ASYNC_STAGE_TIMEOUT_SEC:-600}"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
ASYNC_INPUT="$OUT_DIR/async_input.vibe"
ASYNC_OUTPUT="$OUT_DIR/async_output.wasm"
PLAIN_INPUT="$OUT_DIR/plain_input.vibe"
PLAIN_OUTPUT="$OUT_DIR/plain_output.wasm"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"
EXPECTED="42"

WASM_RUN_FLAGS=(-W exceptions=y -W concurrency-support=y -W component-model-async=y -W component-model-async-stackful=y)

run_with_timeout() {
  local t="$1"; shift
  if [ "$t" -le 0 ]; then "$@"; return $?; fi
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$@"; return $?; fi
  "$@"
}

magic8() { od -An -t x1 -N 8 "$1" | tr -d ' \n'; }

# --- preconditions (skip if tooling missing) ---
if ! command -v node >/dev/null 2>&1; then
  echo "[async-gate] SKIP: node not found"; exit 0
fi
if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "[async-gate] SKIP: wasm-tools not found"; exit 0
fi
if [ ! -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]; then
  echo "[async-gate] SKIP: wasm host runner not found"; exit 0
fi
WASMTIME_BIN="$("$PROJECT_ROOT/scripts/wasmtime_bin.sh" 2>/dev/null || command -v wasmtime || true)"
if [ -z "${WASMTIME_BIN:-}" ] || ! "$WASMTIME_BIN" --version >/dev/null 2>&1; then
  echo "[async-gate] SKIP: wasmtime not found"; exit 0
fi
echo "[async-gate] wasmtime: $($WASMTIME_BIN --version)"

if [ -x "$HOST_VIBE_EXE" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then
  HOST_COMPILE=("$HOST_VIBE_EXE_DEBUG" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

mkdir -p "$OUT_DIR"
rm -f "$STAGE1_CORE_WASM" "$ASYNC_OUTPUT" "$PLAIN_OUTPUT"

echo "[async-gate] stage0 -> stage1 selfhost compiler core wasm"
run_with_timeout "$STAGE_TIMEOUT_SEC" "${HOST_COMPILE[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM"
if [ "$(magic8 "$STAGE1_CORE_WASM")" != "0061736d01000000" ]; then
  echo "[async-gate] FAIL: stage1 is not a core module" >&2; exit 1
fi

printf 'let run: () -> Int with { Async } = () -> { %s }\n' "$EXPECTED" > "$ASYNC_INPUT"
printf 'let run: () -> Int = () -> { %s }\n' "$EXPECTED" > "$PLAIN_INPUT"

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"
compile_via_stage1() {
  local in="$1" out="$2"
  run_with_timeout "$STAGE_TIMEOUT_SEC" \
    env VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
        --invoke selfbuild_cli_args_entry "$STAGE1_CORE_WASM" \
        "${in#$PROJECT_ROOT/}" "${out#$PROJECT_ROOT/}" run >/dev/null
}

echo "[async-gate] stage1 compiles async entry"
compile_via_stage1 "$ASYNC_INPUT" "$ASYNC_OUTPUT"
echo "[async-gate] stage1 compiles non-async control entry"
compile_via_stage1 "$PLAIN_INPUT" "$PLAIN_OUTPUT"
unset VIBE_PREOPEN_DIR

# async output must be a component
if [ "$(magic8 "$ASYNC_OUTPUT")" != "0061736d0d000100" ]; then
  echo "[async-gate] FAIL: async output is not a component (magic=$(magic8 "$ASYNC_OUTPUT"))" >&2; exit 1
fi
echo "[async-gate] async output is a component"

# non-async control must stay a plain core module (no async leakage)
if [ "$(magic8 "$PLAIN_OUTPUT")" != "0061736d01000000" ]; then
  echo "[async-gate] FAIL: non-async output is not a plain core module (magic=$(magic8 "$PLAIN_OUTPUT"))" >&2; exit 1
fi
echo "[async-gate] non-async control is a plain core module (no regression)"

wasm-tools validate --features all "$ASYNC_OUTPUT" >/dev/null
echo "[async-gate] async component validates"

result="$("$WASMTIME_BIN" run "${WASM_RUN_FLAGS[@]}" --invoke "run()" "$ASYNC_OUTPUT" 2>&1 | grep -E '^-?[0-9]+$' | tail -n 1 || true)"
if [ "$result" != "$EXPECTED" ]; then
  echo "[async-gate] FAIL: async component returned '$result' (expected $EXPECTED)" >&2; exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### WASI 0.3 Async Component Gate"
    echo
    echo "- stage1 selfhost compiler compiled \`run : () -> Int with { Async }\` to an async-lifted component"
    echo "- component validated and ran on wasmtime, returning \`$EXPECTED\`"
    echo "- non-async control stayed a plain core module (no regression)"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "[async-gate] PASS: selfhost async component runs on wasmtime ($result)"

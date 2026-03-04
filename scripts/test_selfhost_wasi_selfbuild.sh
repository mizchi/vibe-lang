#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
STAGE1_WASM="$OUT_DIR/index_stage1.wasm"
STAGE2_WASM="$OUT_DIR/index_stage2.wasm"

run_stage() {
  local name="$1"
  shift
  local start end elapsed
  start="$(date +%s)"
  echo "[selfbuild] $name"
  "$@"
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[selfbuild] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost WASI Selfbuild Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

run_stage "stage0 (wasm compiler cli) -> stage1 wasm compile" \
  moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm-mvp "$ENTRY_PATH" -o "$STAGE1_WASM"

if ! command -v moonrun >/dev/null 2>&1; then
  echo "selfbuild gate failed: moonrun not found" >&2
  exit 1
fi
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  echo "selfbuild gate failed: stage1 compiler wasm not found: $STAGE1_COMPILER_WASM" >&2
  exit 1
fi

run_stage "stage1 (wasm compiler via moonrun) -> stage2 wasm compile" \
  moonrun "$STAGE1_COMPILER_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE2_WASM"

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate stage1 wasm" wasm-tools validate --features all "$STAGE1_WASM"
  run_stage "validate stage2 wasm" wasm-tools validate --features all "$STAGE2_WASM"
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_STAGE1="$(shasum -a 256 "$STAGE1_WASM" | awk '{print $1}')"
HASH_STAGE2="$(shasum -a 256 "$STAGE2_WASM" | awk '{print $1}')"
if [ "$HASH_STAGE1" != "$HASH_STAGE2" ]; then
  echo "selfbuild gate failed: stage1/stage2 wasm hash mismatch" >&2
  echo "  stage1: $HASH_STAGE1" >&2
  echo "  stage2: $HASH_STAGE2" >&2
  exit 1
fi

stage1_run_start="$(date +%s)"
echo "[selfbuild] run stage1 wasm via wasmtime (--invoke run)"
env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE1_WASM" >"$OUT_DIR/stage1_run.out"
stage1_run_end="$(date +%s)"
stage1_run_elapsed="$((stage1_run_end - stage1_run_start))"
echo "[selfbuild] done: run stage1 wasm via wasmtime (--invoke run) (${stage1_run_elapsed}s)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "run stage1 wasm via wasmtime (--invoke run)" "$stage1_run_elapsed" >> "$GITHUB_STEP_SUMMARY" || true
fi

stage2_run_start="$(date +%s)"
echo "[selfbuild] run stage2 wasm via wasmtime (--invoke run)"
env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE2_WASM" >"$OUT_DIR/stage2_run.out"
stage2_run_end="$(date +%s)"
stage2_run_elapsed="$((stage2_run_end - stage2_run_start))"
echo "[selfbuild] done: run stage2 wasm via wasmtime (--invoke run) (${stage2_run_elapsed}s)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "run stage2 wasm via wasmtime (--invoke run)" "$stage2_run_elapsed" >> "$GITHUB_STEP_SUMMARY" || true
fi

RUN_STAGE1="$(rg -v '^warning' "$OUT_DIR/stage1_run.out" | tail -n 1)"
RUN_STAGE2="$(rg -v '^warning' "$OUT_DIR/stage2_run.out" | tail -n 1)"
if ! [[ "$RUN_STAGE1" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage1 run did not return numeric value: $RUN_STAGE1" >&2
  exit 1
fi
if ! [[ "$RUN_STAGE2" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage2 run did not return numeric value: $RUN_STAGE2" >&2
  exit 1
fi

if [ "$RUN_STAGE1" != "0" ]; then
  echo "selfbuild gate failed: expected stage1 run return 0, got $RUN_STAGE1" >&2
  exit 1
fi
if [ "$RUN_STAGE2" != "0" ]; then
  echo "selfbuild gate failed: expected stage2 run return 0, got $RUN_STAGE2" >&2
  exit 1
fi

echo "selfbuild gate passed: hash=$HASH_STAGE1 stage1_run=$RUN_STAGE1 stage2_run=$RUN_STAGE2"

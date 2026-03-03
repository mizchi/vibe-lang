#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE1_A="$OUT_DIR/index_stage1_a.wasm"
STAGE1_B="$OUT_DIR/index_stage1_b.wasm"

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

run_stage "stage0 (wasm compiler cli) -> stage1 wasm compile (first)" \
  moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm-mvp "$ENTRY_PATH" -o "$STAGE1_A"

run_stage "stage0 (wasm compiler cli) -> stage1 wasm compile (second)" \
  moon run --target wasm src/cmd/vibe_compile_wasi -- --wasm-mvp "$ENTRY_PATH" -o "$STAGE1_B"

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate stage1 wasm (first)" wasm-tools validate --features all "$STAGE1_A"
  run_stage "validate stage1 wasm (second)" wasm-tools validate --features all "$STAGE1_B"
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_A="$(shasum -a 256 "$STAGE1_A" | awk '{print $1}')"
HASH_B="$(shasum -a 256 "$STAGE1_B" | awk '{print $1}')"
if [ "$HASH_A" != "$HASH_B" ]; then
  echo "selfbuild gate failed: stage1 wasm hash mismatch" >&2
  echo "  first : $HASH_A" >&2
  echo "  second: $HASH_B" >&2
  exit 1
fi

stage_run_start="$(date +%s)"
echo "[selfbuild] run stage1 wasm via wasmtime (--invoke run)"
env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE1_A" >"$OUT_DIR/stage1_run.out"
stage_run_end="$(date +%s)"
stage_run_elapsed="$((stage_run_end - stage_run_start))"
echo "[selfbuild] done: run stage1 wasm via wasmtime (--invoke run) (${stage_run_elapsed}s)"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "run stage1 wasm via wasmtime (--invoke run)" "$stage_run_elapsed" >> "$GITHUB_STEP_SUMMARY" || true
fi

RUN_VALUE="$(rg -v '^warning' "$OUT_DIR/stage1_run.out" | tail -n 1)"
if ! [[ "$RUN_VALUE" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage1 run did not return numeric value: $RUN_VALUE" >&2
  exit 1
fi

if [ "$RUN_VALUE" != "0" ]; then
  echo "selfbuild gate failed: expected stage1 run return 0, got $RUN_VALUE" >&2
  exit 1
fi

echo "selfbuild gate passed: hash=$HASH_A run=$RUN_VALUE"

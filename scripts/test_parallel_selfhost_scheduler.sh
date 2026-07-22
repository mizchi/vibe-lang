#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
COMPILER_WASM="${VIBE_PARALLEL_COMPILER_WASM:-}"

cd "$PROJECT_ROOT"

if [ -z "$COMPILER_WASM" ]; then
  short_sha="$(git rev-parse --short HEAD)"
  compiler_inputs_dirty="$(
    git status --porcelain -- \
      lib/@vibe/compiler \
      lib/@vibe/cli \
      bootstrap/seed.json \
      scripts/generate_bundle.sh \
      scripts/generations.sh
  )"
  if [ -z "$compiler_inputs_dirty" ]; then
    COMPILER_WASM="$(
      find _build/selfhost/generations \
        -path "*_${short_sha}/stage2.wasm" -type f -print 2>/dev/null \
        | head -n 1
    )"
  fi
fi

if [ -z "$COMPILER_WASM" ] || [ ! -s "$COMPILER_WASM" ]; then
  out_dir="$PROJECT_ROOT/_build/parallel_scheduler_selfhost"
  echo "[parallel-selfhost] building current stage2 compiler" >&2
  bash scripts/generations.sh build --out-dir "$out_dir" >/dev/null
  COMPILER_WASM="$out_dir/stage2.wasm"
fi

if [ ! -s "$COMPILER_WASM" ]; then
  echo "[parallel-selfhost] compiler not found: $COMPILER_WASM" >&2
  exit 1
fi

echo "[parallel-selfhost] compiler=$COMPILER_WASM" >&2
VIBE_PARALLEL_COMPILER_WASM="$COMPILER_WASM" \
  node --test scripts/parallel_scheduler_selfhost.test.mjs

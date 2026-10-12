#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
COMPILER="${1:-${VIBE_TASKGROUP_COMPILER_WASM:-}}"
if [ -z "$COMPILER" ]; then
  bash scripts/generations.sh build --out-dir _build/taskgroup-lowering-compiler
  COMPILER="$ROOT_DIR/_build/taskgroup-lowering-compiler/stage2.wasm"
fi
OUT="$(mktemp -d "$ROOT_DIR/_build/taskgroup-lowering-test-XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
bash scripts/build_taskgroup_lowering.sh "$COMPILER" "$OUT"
python3 scripts/test_taskgroup_lowering.py "$COMPILER" "$OUT"

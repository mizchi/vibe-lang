#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
COMPILER="${1:-${VIBE_TASKGROUP_COMPILER_WASM:-}}"
if [ -z "$COMPILER" ]; then
  bash scripts/generations.sh build --out-dir _build/taskgroup-functions-compiler
  COMPILER="$ROOT_DIR/_build/taskgroup-functions-compiler/stage2.wasm"
fi
# Product strings cross a reused parent buffer. Pin ownership and bounded
# bump allocation on the engine lane used by the actual function artifacts,
# as well as RC/shadow, always through the explicitly selected compiler.
for rc in 0 1 shadow; do
  VIBE_RC="$rc" VIBE_TEST_CLI_WASM="$COMPILER" bash scripts/vibe_test.sh \
    lib/@vibe/lowering_worker/linear/body_reader_test.vibe \
    lib/@vibe/codegen/transport/body_string_copy_test.vibe
done
OUT="$(mktemp -d "$ROOT_DIR/_build/taskgroup-functions-test-XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
bash scripts/build_taskgroup_functions.sh "$COMPILER" "$OUT"
python3 scripts/test_taskgroup_functions.py "$COMPILER" "$OUT"

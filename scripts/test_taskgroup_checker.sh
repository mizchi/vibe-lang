#!/usr/bin/env bash
# Actual native checks, cancellation and final-build parity, on Linux /proc.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
COMPILER="${1:-${VIBE_TASKGROUP_COMPILER_WASM:-}}"
if [ -z "$COMPILER" ]; then
  bash scripts/generations.sh build --out-dir _build/taskgroup-checker-compiler
  COMPILER="$ROOT_DIR/_build/taskgroup-checker-compiler/stage2.wasm"
fi
COMPILER="$(cd "$(dirname "$COMPILER")" && pwd)/$(basename "$COMPILER")"
mkdir -p _build
OUT="$(mktemp -d "$ROOT_DIR/_build/taskgroup-checker-test-XXXXXX")"
bash scripts/build_taskgroup_checker.sh "$COMPILER" "$OUT"
RUNNER="$ROOT_DIR/runtime/viberun/target/release/viberun"
python3 scripts/checker_taskgroup_worker_test.py --compiler "$COMPILER" --worker "$OUT/worker.wasm" --runner "$RUNNER"
python3 scripts/checker_taskgroup_batch_test.py --compiler "$COMPILER" --worker "$OUT/worker.wasm" \
  --runner "$RUNNER" --coordinator "$OUT/coordinator.component.wasm"
for replay in 0 1; do
  VIBE_PARALLEL_BACKEND=taskgroup VIBE_TASKGROUP_ARTIFACT_DIR="$OUT" \
    VIBE_TASKGROUP_JOB_CACHE="$replay" \
    bash scripts/test_parallel_frontend_warm.sh "$COMPILER"
done
echo "TaskGroup checker dogfood oracle passed; artifacts: $OUT"

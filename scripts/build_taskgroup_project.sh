#!/usr/bin/env bash
# Opt-in dogfood build; include frontend preparation in any time comparison.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -ge 3 ] && [ "$#" -le 6 ] || {
  echo "usage: build_taskgroup_project.sh <compiler> <entry> <output> [entry-function=main] [jobs=4] [artifact-directory]" >&2
  exit 2
}
COMPILER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
ENTRY="$2"; OUTPUT="$3"; ENTRY_FUNCTION="${4:-main}"; JOBS="${5:-4}"
ARTIFACTS="${6:-$ROOT_DIR/_build/taskgroup-checker}"
ARTIFACTS="$(cd "$ARTIFACTS" && pwd)"
PROJECT_ROOT="${VIBE_PREOPEN_DIR:-$PWD}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
for artifact in "$COMPILER" "$ARTIFACTS/worker.wasm" "$ARTIFACTS/coordinator.component.wasm"; do
  [ -s "$artifact" ] || { echo "missing TaskGroup artifact: $artifact" >&2; exit 2; }
done
python3 - "$ARTIFACTS/build.json" "$COMPILER" "$ARTIFACTS" <<'PYVERIFY'
import hashlib, json, sys
from pathlib import Path
receipt_path, compiler, artifacts = map(Path, sys.argv[1:])
receipt = json.loads(receipt_path.read_text())
assert hashlib.sha256(compiler.read_bytes()).hexdigest() == receipt['compiler_sha256'], 'rebuild checker artifacts for this compiler'
for name in ['worker.wasm', 'coordinator.component.wasm']:
    p = artifacts/name
    assert hashlib.sha256(p.read_bytes()).hexdigest() == receipt['artifacts'][str(p)], 'checker artifact changed after its build receipt'
PYVERIFY
bash "$ROOT_DIR/scripts/ensure_viberun.sh"
export VIBE_LIB="${VIBE_LIB:-$ROOT_DIR/lib}" VIBE_PREOPEN_DIR="$PROJECT_ROOT"
export VIBE_IMPORT_ABI="${VIBE_IMPORT_ABI:-raw}"
cd "$PROJECT_ROOT"
if [ "${VIBE_TASKGROUP_DIRECT:-0}" = 1 ]; then
  export VIBE_TASKGROUP_INTERFACE_REPLAY="${VIBE_TASKGROUP_INTERFACE_REPLAY:-1}"
  work="$(mktemp -d "${TMPDIR:-/tmp}/vibe-taskgroup-direct.XXXXXX")"
  if [ "${VIBE_TASKGROUP_KEEP_JOBS:-0}" != 1 ]; then
    trap 'rm -r -- "$work"' EXIT
  fi
  frontend="$ROOT_DIR/scripts/taskgroup_frontend_warm.mjs"
  node "$frontend" "$COMPILER" "$ENTRY" "$JOBS" \
    "$PROJECT_ROOT" "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
    "$ARTIFACTS/worker.wasm" "$ARTIFACTS/coordinator.component.wasm" \
    "$ROOT_DIR/runtime/viberun/target/release/viberun" direct "$work"
  products="$work/checked-products"
  [ -d "$products" ] || products=""
  VIBE_TASKGROUP_CHECKED_PRODUCTS_DIR="$products" VIBE_FS_COMPILE=1 VIBE_RUNNER_EXIT_WITH_RESULT=1 \
    bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
    "$COMPILER" "$ENTRY" "$OUTPUT" "$ENTRY_FUNCTION"
  if [ -n "$products" ] && { [ ! -f "$products/accepted" ] || [ "$(cat "$products/accepted")" != checked-taskgroup-v1 ]; }; then
    echo "final compiler did not consume the TaskGroup checked products" >&2
    exit 1
  fi
  if [ -f "$work/pending-replay.json" ]; then
    node "$frontend" --commit-direct "$work"
  fi
  exit 0
fi
node "$ROOT_DIR/scripts/taskgroup_frontend_warm.mjs" "$COMPILER" "$ENTRY" "$JOBS" \
  "$PROJECT_ROOT" "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  "$ARTIFACTS/worker.wasm" "$ARTIFACTS/coordinator.component.wasm" \
  "$ROOT_DIR/runtime/viberun/target/release/viberun"
VIBE_FS_COMPILE=1 VIBE_RUNNER_EXIT_WITH_RESULT=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke cli_main \
  "$COMPILER" "$ENTRY" "$OUTPUT" "$ENTRY_FUNCTION"

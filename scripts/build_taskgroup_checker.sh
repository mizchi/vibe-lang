#!/usr/bin/env bash
# Experimental build units; the worker follows the compiler's bump policy.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
  echo "usage: build_taskgroup_checker.sh <current-stage2.wasm> [artifact-directory]" >&2
  exit 2
}
COMPILER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -s "$COMPILER" ] || { echo "compiler not found: $COMPILER" >&2; exit 2; }
OUT="${2:-$ROOT_DIR/_build/taskgroup-checker}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORKER_RC="${VIBE_TASKGROUP_WORKER_RC:-0}"
case "$WORKER_RC" in 0|1) ;; *) echo "VIBE_TASKGROUP_WORKER_RC must be 0 or 1" >&2; exit 2 ;; esac
cd "$ROOT_DIR"
bash scripts/ensure_viberun.sh
export VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_LIB="$ROOT_DIR/lib"
export VIBE_BUILD_CACHE_DIR="$OUT/compile-cache"
export VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RUNNER_EXIT_WITH_RESULT=1
export VIBE_WASM_NAMES=1 VIBE_UNSTABLE=1
VIBE_RC="$WORKER_RC" bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  lib/@vibe/checker/worker/worker.vibe "$OUT/worker.wasm" cli_main
# TaskGroup and async resource ownership are exercised on the RC lane.
VIBE_RC=1 bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" \
  lib/@vibe/checker/coordinator/coordinator.vibe "$OUT/coordinator.component.wasm" run
python3 - "$COMPILER" "$OUT" "$ROOT_DIR/runtime/viberun/target/release/viberun" "$WORKER_RC" <<'PY'
import hashlib, json, sys
from pathlib import Path
compiler, out, runner = map(Path, sys.argv[1:4])
assert (out/'worker.wasm').read_bytes()[:8] == b'\0asm\x01\0\0\0'
assert (out/'coordinator.component.wasm').read_bytes()[:8] == b'\0asm\x0d\0\x01\0'
files = [compiler, out/'worker.wasm', out/'coordinator.component.wasm', runner]
receipt = {'compiler_sha256': hashlib.sha256(compiler.read_bytes()).hexdigest(), 'worker_rc': int(sys.argv[4]), 'coordinator_rc': 1,
           'artifacts': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(out/'build.json').write_text(json.dumps(receipt, indent=2)+'\n')
PY
echo "TaskGroup checker artifacts: $OUT"

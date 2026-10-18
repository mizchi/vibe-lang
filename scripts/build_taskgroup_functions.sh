#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
  echo "usage: build_taskgroup_functions.sh <current-stage2.wasm> [artifact-directory]" >&2
  exit 2
}
COMPILER="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="${2:-$ROOT_DIR/_build/taskgroup-functions}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$ROOT_DIR"
bash scripts/ensure_viberun.sh
export VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_LIB="$ROOT_DIR/lib"
export VIBE_BUILD_CACHE_DIR="$OUT/compile-cache"
export VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_RUNNER_EXIT_WITH_RESULT=1
export VIBE_WASM_NAMES=1 VIBE_UNSTABLE=1 VIBE_RC=1
for name in worker compile coordinator; do
  case "$name" in
    worker) source_file=lib/@vibe/function_worker/worker.vibe; entry=main; target=worker.wasm ;;
    compile) source_file=lib/@vibe/function_build/compile.vibe; entry=main; target=compile.wasm ;;
    coordinator) source_file=lib/@vibe/lowering_worker/coordinator/coordinator.vibe; entry=run; target=coordinator.component.wasm ;;
  esac
  if [ "$name" = coordinator ]; then export VIBE_RC=1; else export VIBE_RC=0; fi
  if [ "$name" = compile ]; then export VIBE_WASM_KEEP_EXPORTS=1; else unset VIBE_WASM_KEEP_EXPORTS; fi
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$COMPILER" "$source_file" "$OUT/$target" "$entry"
done
python3 - "$COMPILER" "$OUT" "$ROOT_DIR/runtime/viberun/target/release/viberun" <<'PY'
import hashlib, json, sys
from pathlib import Path
compiler, out, runner = map(Path, sys.argv[1:])
files = [out/'worker.wasm', out/'compile.wasm', out/'coordinator.component.wasm']
receipt = {'version': 1, 'kind': 'vibe-taskgroup-functions', 'function_abi': 'bump-core-tagged-callbacks-1',
           'context_format': 6, 'job_format': 2, 'compile_engine_rc': 0, 'worker_engine_rc': 0, 'coordinator_engine_rc': 1, 'compiler_sha256': hashlib.sha256(compiler.read_bytes()).hexdigest(),
           'runner_sha256': hashlib.sha256(runner.read_bytes()).hexdigest(),
           'artifacts': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(out/'build.json').write_text(json.dumps(receipt, indent=2)+'\n')
PY
echo "TaskGroup function artifacts: $OUT"

#!/usr/bin/env bash
# One-command CPU + memory profile of a real selfhost compile.
#
# Encodes the workflow from .claude/skills/compiler-perf-profiling so a dev
# (or a CI job) gets the hotspot table and the memory high-water in one run
# instead of hand-assembling node flags + a summary script:
#
#   1. node --cpu-prof on a real compile through stage2 (`cli_main`)
#   2. self-time top-N summary of the .cpuprofile (wasm names via name section)
#   3. end-of-run wasm memory stats: bump-heap high-water (`__heap_ptr`),
#      linear memory pages, process RSS (VIBE_WASM_MEMORY_STATS=1)
#
# usage:
#   scripts/profile_compile.sh <stage2.wasm> [input.vibe] [top_n]
#
#   <stage2.wasm>  a selfhost compiler artifact (e.g. the output of
#                  `scripts/generations.sh build`)
#   [input.vibe]   compile target; defaults to a heavy full-closure compile
#                  (lib/@vibe/compiler/tests/codegen_lexer_test.vibe)
#   [top_n]        rows in the self-time table (default 20)
#
# env:
#   VIBE_PROFILE_OUT_DIR  keep the .cpuprofile/out.wasm here instead of a
#                         throwaway temp dir (open the .cpuprofile in
#                         chrome://inspect or speedscope for the full tree)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

STAGE2="${1:-}"
INPUT="${2:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
TOP_N="${3:-20}"
if [ -z "$STAGE2" ] || [ ! -f "$STAGE2" ]; then
  echo "usage: scripts/profile_compile.sh <stage2.wasm> [input.vibe] [top_n]" >&2
  exit 2
fi
if [ ! -f "$INPUT" ]; then
  echo "[profile-compile] input not found: $INPUT" >&2
  exit 2
fi

OUT_DIR="${VIBE_PROFILE_OUT_DIR:-$(mktemp -d)}"
mkdir -p "$OUT_DIR"
PROFILE_NAME="compile.cpuprofile"
OUT_WASM="$OUT_DIR/out.wasm"

echo "[profile-compile] stage2=$STAGE2"
echo "[profile-compile] input=$INPUT"
echo "[profile-compile] out_dir=$OUT_DIR"

start_ns=$(date +%s%N)
# Through the runner wrapper, not a bare `node`: the wrapper adds the wasm
# perf flags every other lane runs with (--experimental-wasm-inlining above
# all -- V8 leaves its wasm-to-wasm inliner OFF for MVP modules unless asked).
# Profiled without it, the small runtime helpers show up as calls V8 would
# have inlined: measured 2026-09-06 on the same cold compile, __rt_arr_get
# 415 -> 156 ms self, __rt_eq 291 -> 114 ms, __rt_arr_len 148 -> 0 ms,
# wall 7.14 -> 6.55 s. Those rows were the profile's artifact, not the
# compiler's cost.
# One flag per line: the wrapper splits VIBE_NODE_EXTRA_FLAGS on newlines, so
# an output directory with a space in its name stays one argument.
extra_flags="$(printf '%s\n' --cpu-prof "--cpu-prof-dir=$OUT_DIR" "--cpu-prof-name=$PROFILE_NAME")"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
  VIBE_WASM_MEMORY_STATS=1 \
  VIBE_NODE_EXTRA_FLAGS="$extra_flags" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
  "$INPUT" "$OUT_WASM" __no_entry__
end_ns=$(date +%s%N)
echo "[profile-compile] wall_ms=$(( (end_ns - start_ns) / 1000000 ))"

python3 - "$OUT_DIR/$PROFILE_NAME" "$TOP_N" <<'PY'
import json, collections, sys
path, top_n = sys.argv[1], int(sys.argv[2])
p = json.load(open(path))
nodes = {n["id"]: n for n in p["nodes"]}
c = collections.Counter()
for sid, dt in zip(p["samples"], p["timeDeltas"]):
    c[nodes[sid]["callFrame"]["functionName"] or "(anon)"] += dt
total = sum(c.values())
print(f"[profile-compile] cpu total {total/1e6:.2f}s, self-time top {top_n}:")
for fn, us in c.most_common(top_n):
    print(f"  {us/1000:8.1f}ms {us*100/total:5.1f}%  {fn[:100]}")
anon = sum(us for fn, us in c.items() if fn.startswith("wasm-function["))
if anon:
    print(f"[profile-compile] WARNING: {anon/1000:.1f}ms in unnamed wasm-function[N] "
          f"frames -- name section gap? (see linked_compile.vibe gen_sec_names)")
PY
echo "[profile-compile] cpuprofile: $OUT_DIR/$PROFILE_NAME"

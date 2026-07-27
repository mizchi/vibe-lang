#!/usr/bin/env bash
# #906: cold/warm wall time + peak guest heap + host RSS KPI for the --jobs N
# frontend pre-warm path (scripts/parallel_frontend_warm.mjs) + the real
# compile that always follows it.
#
# docs/compiler-parallelism.md's "Completion gates" list this explicitly as
# outstanding before raising the default worker count above 1: "cold and
# warm compile time, peak guest heap, and host RSS are reported before
# raising the default worker count." Phase 0's scripts/selfcompile_kpi.sh
# already reports wall time + peak guest heap for a plain SERIAL compile;
# this script reports the same numbers for the pre-warm + compile sequence.
#
# Deliberately does NOT go through runtime/vibe's own `build` command (same
# reason scripts/test_parallel_frontend_warm.sh's own header comment gives):
# (a) its default RUNNER is the Rust `vibewt` binary, not guaranteed built in
# a dev checkout or CI; (b) more importantly, `compile_to()` in runtime/vibe
# captures the underlying runner's stderr into a local temp file and only
# ever prints it on a FAILED compile -- on success it is silently discarded,
# so the VIBE_WASM_MEMORY_STATS `[wasm-memory]` line this script depends on
# never reaches the outside world through that path (confirmed empirically:
# routing through runtime/vibe build produced completely empty stderr on a
# successful compile). Driving the pre-warm driver and the Node runner
# directly, exactly like test_parallel_frontend_warm.sh does, sidesteps both
# issues and matches this repo's own established pattern for exercising this
# subsystem.
#
#   scripts/jobs_kpi.sh [stage2.wasm] [jobs] [input.vibe] [entry]
#
# stage2.wasm: same auto-detect-or-build convention as
# scripts/test_parallel_frontend_warm.sh -- omit to build one fresh under
# _build/jobs_kpi_selfhost.
#
# input.vibe/entry: default to scripts/fixtures/parallel_project_sample's
# leaf/mid/main diamond (the same fixture scripts/test_parallel_frontend_warm.sh
# already uses to exercise --jobs), entry main_value -- small on purpose, so
# the default invocation is a fast correctness smoke test of this script
# itself. Point both args at a bigger real project for a meaningful KPI
# number.
#
# Output (stdout, one line per mode):
#   [jobs-kpi] mode=cold jobs=<n> input=<path> wall_ms=<n> heap_ptr_bytes=<n|?> peak_rss_kb=<n|?>
#   [jobs-kpi] mode=warm jobs=<n> input=<path> wall_ms=<n> heap_ptr_bytes=<n|?> peak_rss_kb=<n|?>
#
# "cold" runs against a freshly created, empty VIBE_BUILD_CACHE_DIR (#849);
# "warm" reruns the identical sequence against that now-populated cache dir,
# so the delta between the two lines is the persistent-cache's own effect on
# top of whatever --jobs itself contributes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

STAGE2="${1:-}"
JOBS="${2:-4}"
INPUT="${3:-scripts/fixtures/parallel_project_sample/main.vibe}"
ENTRY="${4:-main_value}"

if [ -z "$STAGE2" ]; then
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
    STAGE2="$(
      find _build/selfhost/generations \
        -path "*_${short_sha}/stage2.wasm" -type f -print 2>/dev/null \
        | head -n 1
    )"
  fi
fi
if [ -z "$STAGE2" ] || [ ! -s "$STAGE2" ]; then
  out_dir="$ROOT_DIR/_build/jobs_kpi_selfhost"
  echo "[jobs-kpi] building current stage2 compiler" >&2
  bash scripts/generations.sh build --out-dir "$out_dir" >/dev/null
  STAGE2="$out_dir/stage2.wasm"
fi
[ -s "$STAGE2" ] || { echo "[jobs-kpi] compiler not found: $STAGE2" >&2; exit 1; }
STAGE2="$(cd "$(dirname "$STAGE2")" && pwd)/$(basename "$STAGE2")"

case "$JOBS" in
  ''|*[!0-9]*) echo "[jobs-kpi] jobs must be a positive integer, got: $JOBS" >&2; exit 2 ;;
esac
if [ ! -f "$INPUT" ]; then
  echo "[jobs-kpi] input not found: $INPUT" >&2
  exit 2
fi

# GNU time (`/usr/bin/time -v`) reports "Maximum resident set size" for the
# whole process tree it launches -- covers both the Node pre-warm
# coordinator (worker_threads share one OS process/RSS) and the compile
# subprocess spawned after it. The shell builtin `time` exposes no RSS at
# all, and BSD/macOS `time` lacks -v, hence the explicit binary probe.
TIME_BIN=""
if [ -x /usr/bin/time ]; then
  TIME_BIN=/usr/bin/time
fi
if [ -z "$TIME_BIN" ]; then
  echo "[jobs-kpi] /usr/bin/time -v not available on this platform -- host RSS will be reported as '?' (wall_ms/heap_ptr_bytes are still accurate)" >&2
fi

NODE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
DRIVER="$ROOT_DIR/scripts/parallel_frontend_warm.mjs"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
CACHE_DIR="$OUT_DIR/cache"
mkdir -p "$CACHE_DIR"
OUT_WASM="$OUT_DIR/out.wasm"

# Runs the pre-warm driver + the real compile as one shell function, so a
# single `time -v` wrapper covers both (the completion gate asks for the
# combined cost of the --jobs path, not the driver alone).
run_sequence() {
  VIBE_BUILD_CACHE_DIR="$CACHE_DIR" \
    node "$DRIVER" "$STAGE2" "$INPUT" "$JOBS" "$ROOT_DIR" "$NODE_RUNNER" >/dev/null
  rm -f "$OUT_WASM" "$OUT_WASM.diag"
  VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_WASM_MEMORY_STATS=1 \
    VIBE_BUILD_CACHE_DIR="$CACHE_DIR" \
    bash "$NODE_RUNNER" --invoke cli_main "$STAGE2" "$INPUT" "$OUT_WASM" "$ENTRY"
}

run_once() {
  local mode="$1"
  local time_log="$OUT_DIR/time_$mode.log"
  local start_ns end_ns wall_ms heap_ptr_bytes peak_rss_kb
  start_ns=$(date +%s%N)
  if [ -n "$TIME_BIN" ]; then
    "$TIME_BIN" -v bash -c 'run_sequence' >/dev/null 2>"$time_log" || true
  else
    run_sequence >/dev/null 2>"$time_log" || true
  fi
  end_ns=$(date +%s%N)
  wall_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ ! -s "$OUT_WASM" ]; then
    echo "[jobs-kpi] mode=$mode build produced no output wasm" >&2
    tail -20 "$time_log" >&2 || true
    exit 1
  fi
  # last [wasm-memory] line is the end-of-run high-water for the real
  # compile's own invocation (the driver's own per-module check calls are
  # separate short-lived instantiations and don't share this global).
  heap_ptr_bytes="$(grep '\[wasm-memory\]' "$time_log" 2>/dev/null | tail -1 | sed -n 's/.*heap_ptr=\([0-9][0-9]*\).*/\1/p' || true)"
  [ -n "$heap_ptr_bytes" ] || heap_ptr_bytes="?"
  peak_rss_kb="?"
  if [ -n "$TIME_BIN" ]; then
    peak_rss_kb="$(sed -n 's/.*Maximum resident set size (kbytes): \([0-9][0-9]*\).*/\1/p' "$time_log" 2>/dev/null | tail -1 || true)"
    [ -n "$peak_rss_kb" ] || peak_rss_kb="?"
  fi
  echo "[jobs-kpi] mode=$mode jobs=$JOBS input=$INPUT wall_ms=$wall_ms heap_ptr_bytes=$heap_ptr_bytes peak_rss_kb=$peak_rss_kb"
}

export -f run_sequence
export ROOT_DIR DRIVER STAGE2 INPUT JOBS NODE_RUNNER CACHE_DIR OUT_WASM ENTRY

run_once cold
run_once warm

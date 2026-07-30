#!/usr/bin/env bash
# #906: cold/warm wall time + peak guest heap + peak aggregate host RSS KPI
# for the --jobs N frontend pre-warm path (scripts/parallel_frontend_warm.mjs)
# + the real compile that always follows it.
#
# docs/compiler-parallelism.md's "Completion gates" list this explicitly as
# outstanding before raising the default worker count above 1: "cold and
# warm compile time, peak guest heap, and host RSS are reported". Phase 0's
# scripts/selfcompile_kpi.sh already reports wall time + peak guest heap for
# a plain SERIAL compile; this reports the same numbers for the pre-warm +
# compile sequence.
#
# Deliberately does NOT go through runtime/vibe's own `build` command (same
# reason scripts/test_parallel_frontend_warm.sh's own header comment gives):
# (a) its default RUNNER is the Rust `viberun` binary, not guaranteed built in
# a dev checkout or CI; (b) more importantly, `compile_to()` in runtime/vibe
# captures the underlying runner's stderr into a local temp file and only
# ever prints it on a FAILED compile -- on success it is silently discarded,
# so the VIBE_WASM_MEMORY_STATS `[wasm-memory]` line this script depends on
# never reaches the outside world through that path (confirmed empirically:
# routing through runtime/vibe build produced completely empty stderr on a
# successful compile). Driving the pre-warm driver and the Node runner
# directly, exactly like test_parallel_frontend_warm.sh does, sidesteps both
# issues and matches this repo's own established pattern for exercising this
# subsystem. Mirrors runtime/vibe's own `maybe_warm_frontend_cache` gate
# (jobs > 1) rather than always invoking the driver, so a `jobs=1` run
# measures the true serial baseline the product actually takes at jobs=1
# (Codex review, PR #1163).
#
# Known, deliberate measurement gaps (documented rather than silently
# claimed away -- Codex review, PR #1163):
#   - heap_ptr_bytes covers ONLY the final compile step's own guest heap
#     (VIBE_WASM_MEMORY_STATS), not the pre-warm daemon workers'. Those
#     workers run in --daemon mode (scripts/parallel_scheduler_worker.mjs),
#     which returns before scripts/wasm_vibe_host_runner.js's own
#     emitWasmMemoryStats call -- surfacing a worker's own heap high-water
#     would need a change to the daemon IPC protocol itself, out of scope
#     for this KPI script. Read this number as a lower bound / the same
#     number scripts/selfcompile_kpi.sh already reports for the equivalent
#     serial compile, not the whole sequence's peak.
#   - peak_rss_kb IS the true peak AGGREGATE (sum across every live
#     descendant process, sampled repeatedly while the sequence runs) --
#     NOT `/usr/bin/time -v`'s "Maximum resident set size", which tracks
#     only the single largest descendant at any one instant and would
#     understate cost that scales with concurrent worker count.
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

NODE_RUNNER="$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh"
DRIVER="$ROOT_DIR/scripts/parallel_frontend_warm.mjs"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT
CACHE_DIR="$OUT_DIR/cache"
mkdir -p "$CACHE_DIR"
OUT_WASM="$OUT_DIR/out.wasm"

# Sum RSS (KB) of `root` and every live descendant, from one `ps` snapshot
# (avoids races between separate per-pid queries). Portable POSIX awk, no
# GNU-specific ps flags -- works identically under Linux and macOS/BSD ps.
sum_tree_rss() {
  local root="$1"
  ps -eo pid,ppid,rss 2>/dev/null | awk -v root="$root" '
    NR > 1 { ppid[$1] = $2; rss[$1] = $3 }
    END {
      queue[1] = root; qn = 1; total = 0
      while (qn > 0) {
        cur = queue[qn]; qn--
        if (cur in rss) { total += rss[cur] }
        for (p in ppid) {
          if (ppid[p] == cur) { qn++; queue[qn] = p }
        }
      }
      print total
    }'
}

# Poll the whole descendant tree of `root_pid` every 100ms until it exits,
# tracking the peak AGGREGATE (sum of every live descendant at each sample),
# not just the single largest process -- `/usr/bin/time -v`'s own "Maximum
# resident set size" only tracks the latter, which understates cost that
# scales with concurrent --jobs worker count (Codex review, PR #1163).
track_peak_rss() {
  local root_pid="$1" out_file="$2"
  local peak=0 cur
  while kill -0 "$root_pid" 2>/dev/null; do
    cur="$(sum_tree_rss "$root_pid" 2>/dev/null || echo 0)"
    case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
    if [ "$cur" -gt "$peak" ]; then peak="$cur"; fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  echo "$peak" > "$out_file"
}

# Runs the pre-warm driver (skipped for jobs<=1, mirroring runtime/vibe's own
# `maybe_warm_frontend_cache` gate -- Codex review) + the real compile.
# Explicitly checks and propagates the driver's own exit status: a `|| true`
# anywhere in this sequence would let a crashed/failed driver (worker crash,
# discovery error, invalid jobs value the driver itself rejects, publish
# failure) silently fall through to a successful serial-only compile, making
# a genuinely broken parallel path look like valid --jobs KPI data (Codex
# review, PR #1163).
run_sequence() {
  if [ "$JOBS" -gt 1 ]; then
    local driver_status=0
    VIBE_BUILD_CACHE_DIR="$CACHE_DIR" \
      node "$DRIVER" "$STAGE2" "$INPUT" "$JOBS" "$ROOT_DIR" "$NODE_RUNNER" >/dev/null || driver_status=$?
    if [ "$driver_status" -ne 0 ]; then
      echo "[jobs-kpi] pre-warm driver failed (exit $driver_status)" >&2
      return 1
    fi
  fi
  rm -f "$OUT_WASM" "$OUT_WASM.diag"
  VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw VIBE_WASM_MEMORY_STATS=1 \
    VIBE_BUILD_CACHE_DIR="$CACHE_DIR" \
    bash "$NODE_RUNNER" --invoke cli_main "$STAGE2" "$INPUT" "$OUT_WASM" "$ENTRY"
}

run_once() {
  local mode="$1"
  local time_log="$OUT_DIR/time_$mode.log"
  local rss_file="$OUT_DIR/rss_$mode.txt"
  local start_ns end_ns wall_ms heap_ptr_bytes peak_rss_kb seq_pid tracker_pid seq_status
  start_ns=$(date +%s%N)
  run_sequence >/dev/null 2>"$time_log" &
  seq_pid=$!
  track_peak_rss "$seq_pid" "$rss_file" &
  tracker_pid=$!
  seq_status=0
  wait "$seq_pid" || seq_status=$?
  # Let the tracker notice seq_pid's death on its own next poll tick and
  # write its final peak (up to one sleep interval away) instead of killing
  # it mid-sleep, which would drop the trailing `echo "$peak" > out_file`
  # and leave rss_file empty every time.
  wait "$tracker_pid" 2>/dev/null || true
  end_ns=$(date +%s%N)
  wall_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$seq_status" -ne 0 ] || [ ! -s "$OUT_WASM" ]; then
    echo "[jobs-kpi] mode=$mode build sequence failed (exit $seq_status) or produced no output wasm" >&2
    tail -20 "$time_log" >&2 || true
    exit 1
  fi
  # last [wasm-memory] line is the end-of-run high-water for the real
  # compile's own invocation -- see the header comment's "known gaps" note
  # for why pre-warm daemon workers are NOT reflected here.
  heap_ptr_bytes="$(grep '\[wasm-memory\]' "$time_log" 2>/dev/null | tail -1 | sed -n 's/.*heap_ptr=\([0-9][0-9]*\).*/\1/p' || true)"
  [ -n "$heap_ptr_bytes" ] || heap_ptr_bytes="?"
  peak_rss_kb="$(cat "$rss_file" 2>/dev/null || true)"
  case "$peak_rss_kb" in ''|0|*[!0-9]*) peak_rss_kb="?" ;; esac
  echo "[jobs-kpi] mode=$mode jobs=$JOBS input=$INPUT wall_ms=$wall_ms heap_ptr_bytes=$heap_ptr_bytes peak_rss_kb=$peak_rss_kb"
}

run_once cold
run_once warm

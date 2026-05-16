#!/usr/bin/env bash
# Profile vibe test memory consumption + process tree over time.
#
# Records RSS per descendant process (vibe parent, batch children, wasmtime,
# sh, etc.) at a fixed interval, plus orphan-detection signals (PPID==1 of
# processes whose pgid matches the test runner). Output:
#
#   _build/profile/vibe_test_memory/<run_id>/
#     parent_time.txt        — /usr/bin/time -v on the parent vibe test
#     samples.csv            — t_s,pid,ppid,pgid,rss_kb,vsz_kb,comm,cmd_short
#     orphans.csv            — t_s,pid,ppid,pgid,reason,cmd_short
#     peak_summary.txt       — per-pid peak RSS + cmd
#     summary.json           — overall stats
#
# Usage:
#   scripts/profile_vibe_test_memory.sh [--interval 0.5] [--out DIR] -- <vibe-test-args>
#
# Example:
#   scripts/profile_vibe_test_memory.sh -- vibe/prelude
#   scripts/profile_vibe_test_memory.sh --interval 1 -- vibe/json vibe/parser
set -euo pipefail

INTERVAL="0.5"
OUT_BASE=""
declare -a TEST_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --out)      OUT_BASE="$2"; shift 2 ;;
    --)         shift; TEST_ARGS=("$@"); break ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "profile_vibe_test_memory: unknown arg '$1' (use -- to delimit vibe test args)" >&2
      exit 2
      ;;
  esac
done

if [ "${#TEST_ARGS[@]}" -eq 0 ]; then
  echo "profile_vibe_test_memory: no vibe test args given. usage: $0 [--interval N] -- <args>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$ROOT_DIR/_build/native/release/build/cmd/vibe/vibe.exe}"

if [ ! -x "$VIBE_BIN" ]; then
  echo "profile_vibe_test_memory: vibe binary not found: $VIBE_BIN" >&2
  echo "  build it via: moon build --target native --release src/cmd/vibe" >&2
  exit 1
fi

if [ -z "$OUT_BASE" ]; then
  OUT_BASE="$ROOT_DIR/_build/profile/vibe_test_memory"
fi
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUT_BASE/$RUN_ID"
mkdir -p "$OUT_DIR"

SAMPLES_CSV="$OUT_DIR/samples.csv"
ORPHANS_CSV="$OUT_DIR/orphans.csv"
PARENT_TIME="$OUT_DIR/parent_time.txt"
PEAK_SUMMARY="$OUT_DIR/peak_summary.txt"
SUMMARY_JSON="$OUT_DIR/summary.json"

echo "t_s,pid,ppid,pgid,rss_kb,vsz_kb,comm,cmd_short" > "$SAMPLES_CSV"
echo "t_s,pid,ppid,pgid,reason,cmd_short" > "$ORPHANS_CSV"

echo "profile run id: $RUN_ID"
echo "output dir:     $OUT_DIR"
echo "interval:       ${INTERVAL}s"
echo "command:        vibe test ${TEST_ARGS[*]}"
echo

# Launch vibe test under /usr/bin/time -v in its own process group.
# `setsid` ensures it gets a new session so we can identify all descendants
# by SID == parent PID.
LAUNCH_LOG="$OUT_DIR/launch.log"
( setsid /usr/bin/time -v -o "$PARENT_TIME" \
    "$VIBE_BIN" test "${TEST_ARGS[@]}" \
    > "$OUT_DIR/test_stdout.log" \
    2> "$OUT_DIR/test_stderr.log" ) &
TIME_PID=$!

# /usr/bin/time forks vibe — find the actual vibe pid (its child).
# Wait briefly for vibe to spawn.
sleep 0.2
VIBE_PID=""
for _ in $(seq 1 20); do
  VIBE_PID="$(ps --ppid "$TIME_PID" -o pid= 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -n "$VIBE_PID" ]; then
    break
  fi
  sleep 0.1
done

if [ -z "$VIBE_PID" ]; then
  echo "profile_vibe_test_memory: could not find vibe child of /usr/bin/time (pid=$TIME_PID)" >&2
  VIBE_PID="$TIME_PID"
fi

VIBE_SID="$(ps -o sid= -p "$VIBE_PID" 2>/dev/null | tr -d ' ' || echo "")"
VIBE_PGID="$(ps -o pgid= -p "$VIBE_PID" 2>/dev/null | tr -d ' ' || echo "")"

echo "vibe pid:  $VIBE_PID  sid: $VIBE_SID  pgid: $VIBE_PGID" | tee -a "$LAUNCH_LOG"

START_TS="$(date +%s.%N)"

# Sampling loop — runs as long as vibe is alive, plus 2 extra samples
# after exit to catch lingering descendants.
post_exit_samples=0
declare -A peak_rss=()
declare -A peak_cmd=()
declare -A peak_comm=()
seen_orphans=""

while :; do
  # Did vibe exit?
  if ! kill -0 "$VIBE_PID" 2>/dev/null; then
    post_exit_samples=$((post_exit_samples + 1))
    if [ "$post_exit_samples" -gt 4 ]; then
      break
    fi
  fi

  NOW="$(date +%s.%N)"
  T_S="$(awk -v a="$NOW" -v b="$START_TS" 'BEGIN{printf "%.3f", a - b}')"

  # All descendants of vibe (and the vibe itself).
  # Using --sid lets us catch grandchildren that re-parented.
  if [ -n "$VIBE_SID" ]; then
    PS_FILTER="-s $VIBE_SID"
  else
    PS_FILTER="-p $VIBE_PID"
  fi

  # ps fields: pid ppid pgid rss vsz comm args
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    set -- $line
    pid="$1"; ppid="$2"; pgid="$3"; rss="$4"; vsz="$5"; comm="$6"
    shift 6
    cmd="$*"
    cmd_short="${cmd:0:120}"
    # CSV escape: replace commas with semicolons in cmd
    cmd_csv="${cmd_short//,/;}"
    printf "%s,%s,%s,%s,%s,%s,%s,%s\n" "$T_S" "$pid" "$ppid" "$pgid" "$rss" "$vsz" "$comm" "$cmd_csv" >> "$SAMPLES_CSV"

    # Track peak.
    prev="${peak_rss[$pid]:-0}"
    if [ "$rss" -gt "$prev" ]; then
      peak_rss[$pid]="$rss"
      peak_cmd[$pid]="$cmd_csv"
      peak_comm[$pid]="$comm"
    fi

    # Orphan detection: ppid == 1 but pgid matches vibe session (catches
    # re-parented descendants after batch worker died).
    if [ "$ppid" = "1" ] && [ "$pid" != "$VIBE_PID" ]; then
      if [[ "$seen_orphans" != *"|$pid|"* ]]; then
        seen_orphans="$seen_orphans|$pid|"
        printf "%s,%s,%s,%s,%s,%s\n" "$T_S" "$pid" "$ppid" "$pgid" "reparented_to_init" "$cmd_csv" >> "$ORPHANS_CSV"
      fi
    fi
  done < <(ps $PS_FILTER -o pid=,ppid=,pgid=,rss=,vsz=,comm=,args= 2>/dev/null)

  sleep "$INTERVAL"
done

# Wait for /usr/bin/time wrapper to fully exit & flush.
wait "$TIME_PID" 2>/dev/null || true

# Post-exit orphan sweep: anything still in the session with ppid==1.
sleep 0.5
if [ -n "$VIBE_SID" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    set -- $line
    pid="$1"; ppid="$2"; pgid="$3"
    shift 3
    cmd="$*"
    cmd_short="${cmd:0:120}"
    cmd_csv="${cmd_short//,/;}"
    if [ "$ppid" = "1" ] && [[ "$seen_orphans" != *"|$pid|"* ]]; then
      printf "POST_EXIT,%s,%s,%s,%s,%s\n" "$pid" "$ppid" "$pgid" "still_alive_after_parent_exit" "$cmd_csv" >> "$ORPHANS_CSV"
    fi
  done < <(ps -s "$VIBE_SID" -o pid=,ppid=,pgid=,args= 2>/dev/null)
fi

# Peak summary.
{
  echo "pid  peak_rss_kb  comm  cmd"
  for pid in "${!peak_rss[@]}"; do
    printf "%s  %s  %s  %s\n" "$pid" "${peak_rss[$pid]}" "${peak_comm[$pid]}" "${peak_cmd[$pid]}"
  done | sort -k2 -n -r
} > "$PEAK_SUMMARY"

# Aggregate summary.
sample_count="$(($(wc -l < "$SAMPLES_CSV") - 1))"
orphan_count="$(($(wc -l < "$ORPHANS_CSV") - 1))"
distinct_pids="$(awk -F, 'NR>1{print $2}' "$SAMPLES_CSV" | sort -u | wc -l)"
sum_peak_rss="$(awk '{s+=$1} END{print s+0}' < <(for v in "${peak_rss[@]}"; do echo "$v"; done))"
max_peak_rss="$(awk 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m}' < <(for v in "${peak_rss[@]}"; do echo "$v"; done))"
parent_max_rss="$(awk -F': ' '/Maximum resident set size/{print $2; exit}' "$PARENT_TIME" 2>/dev/null || echo "?")"
parent_wall="$(awk -F': ' '/Elapsed \(wall clock\) time/{print $2; exit}' "$PARENT_TIME" 2>/dev/null || echo "?")"

cat > "$SUMMARY_JSON" <<EOF
{
  "run_id": "$RUN_ID",
  "interval_s": $INTERVAL,
  "test_args": "${TEST_ARGS[*]}",
  "vibe_pid": $VIBE_PID,
  "vibe_sid": "$VIBE_SID",
  "samples": $sample_count,
  "distinct_pids": $distinct_pids,
  "orphans": $orphan_count,
  "sum_peak_rss_kb": $sum_peak_rss,
  "max_per_proc_peak_rss_kb": $max_peak_rss,
  "parent_max_rss_kb": "$parent_max_rss",
  "parent_wall_time": "$parent_wall"
}
EOF

echo
echo "=== summary ==="
cat "$SUMMARY_JSON"
echo
echo "=== top 10 peak RSS by pid ==="
head -11 "$PEAK_SUMMARY"
echo
echo "=== orphans ==="
if [ "$orphan_count" -gt 0 ]; then
  cat "$ORPHANS_CSV"
else
  echo "(none detected)"
fi
echo
echo "all output → $OUT_DIR"

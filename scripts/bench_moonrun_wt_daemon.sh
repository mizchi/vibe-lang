#!/usr/bin/env bash
# Measure the wall-clock benefit of viberun's --daemon mode versus
# one-shot mode. Confirms the #400 win (warm-instance reuse skips the
# 179ms `ensure_builtin_modules` cold-start cost on second+ requests).
#
# Usage:
#   scripts/bench_moonrun_wt_daemon.sh [case ...]
# Env:
#   VIBE_DAEMON_BENCH_REPS    requests per mode (default: 5)
#   VIBE_DAEMON_BENCH_WARMUP  one-shot warmup invocations to discard
#                             (default: 1; soaks up any cwasm/jit cache misses)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

WT_BIN="${MOONRUN_WT_BIN:-$PROJECT_ROOT/runtime/viberun/target/release/viberun}"
if [ ! -x "$WT_BIN" ]; then
  echo "bench-moonrun-wt-daemon: build viberun first" >&2
  exit 1
fi

CHECK_WASM="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.cwasm"
[ ! -f "$CHECK_WASM" ] && CHECK_WASM="$PROJECT_ROOT/_build/wasm/opt/vibe_check_wasi.wasm"
[ ! -f "$CHECK_WASM" ] && {
  echo "bench-moonrun-wt-daemon: stage1 check wasm not found (run perf bench first)" >&2
  exit 1
}

REPS="${VIBE_DAEMON_BENCH_REPS:-5}"
WARMUP="${VIBE_DAEMON_BENCH_WARMUP:-1}"

cases=("$@")
if [ "${#cases[@]}" -eq 0 ]; then
  cases=("examples/basics.vibe")
fi

ms() { perl -MTime::HiRes=time -e 'printf("%.3f\n", time() * 1000)'; }

echo "wasm:  ${CHECK_WASM#${PROJECT_ROOT}/}"
echo "cases: ${cases[*]}"
echo "reps:  $REPS  (warmup: $WARMUP)"
echo

for case_rel in "${cases[@]}"; do
  case_path="$PROJECT_ROOT/$case_rel"
  if [ ! -f "$case_path" ]; then
    echo "SKIP $case_rel (not found)"
    continue
  fi

  # warmup
  for _ in $(seq 1 "$WARMUP"); do
    "$WT_BIN" "$CHECK_WASM" --check "$case_path" >/dev/null
  done

  # one-shot: time each invocation independently
  oneshot_total_ms=0
  for _ in $(seq 1 "$REPS"); do
    t0="$(ms)"
    "$WT_BIN" "$CHECK_WASM" --check "$case_path" >/dev/null
    t1="$(ms)"
    oneshot_total_ms="$(awk -v a="$oneshot_total_ms" -v b="$t1" -v c="$t0" 'BEGIN { printf("%.3f", a + (b - c)) }')"
  done

  # daemon: one process, N requests piped in
  req_file="$(mktemp)"
  for _ in $(seq 1 "$REPS"); do
    python3 -c "import json,sys; print(json.dumps({'args':['--check', sys.argv[1]]}))" "$case_path" >> "$req_file"
  done
  t0="$(ms)"
  "$WT_BIN" --daemon "$CHECK_WASM" < "$req_file" > /dev/null 2>&1
  t1="$(ms)"
  daemon_total_ms="$(awk -v a="$t1" -v b="$t0" 'BEGIN { printf("%.3f", a - b) }')"
  rm -f "$req_file"

  oneshot_avg="$(awk -v t="$oneshot_total_ms" -v r="$REPS" 'BEGIN { printf("%.1f", t / r) }')"
  daemon_avg="$(awk -v t="$daemon_total_ms" -v r="$REPS" 'BEGIN { printf("%.1f", t / r) }')"
  speedup="$(awk -v o="$oneshot_total_ms" -v d="$daemon_total_ms" 'BEGIN { if (d == 0) print "inf"; else printf("%.2fx", o / d) }')"
  saved_pct="$(awk -v o="$oneshot_total_ms" -v d="$daemon_total_ms" 'BEGIN { if (o == 0) print "0%"; else printf("%.0f%%", (1 - d / o) * 100) }')"

  printf "%-50s  oneshot %sms (avg %s)  daemon %sms (avg %s)  speedup %s  saved %s\n" \
    "$case_rel" "$oneshot_total_ms" "$oneshot_avg" "$daemon_total_ms" "$daemon_avg" "$speedup" "$saved_pct"
done

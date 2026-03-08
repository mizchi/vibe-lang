#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI_BIN="$ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
REPORT_DIR="${VIBE_BENCH_KPI_DIR:-$ROOT_DIR/dist/bench_kpi}"
REPORT_FILE="${VIBE_BENCH_KPI_REPORT:-$REPORT_DIR/latest.tsv}"
N_RAW="${VIBE_BENCH_KPI_N:-}"
WARMUP_RAW="${VIBE_BENCH_KPI_WARMUP:-}"
BACKEND="${VIBE_BENCH_KPI_BACKEND:-compiled}"
MAX_PER_US="${VIBE_BENCH_KPI_MAX_PER_US:-}"
MAX_WASM_BYTES="${VIBE_BENCH_KPI_MAX_WASM_BYTES:-}"
MAX_SCORE="${VIBE_BENCH_KPI_MAX_SCORE:-}"

if [[ "$BACKEND" != "compiled" && "$BACKEND" != "wasm" && "$BACKEND" != "interpreter" ]]; then
  echo "bench-kpi: invalid backend: $BACKEND (expected compiled|interpreter)" >&2
  exit 2
fi

if [[ -n "$N_RAW" ]]; then
  N="$N_RAW"
  LEGACY_MODE=1
else
  N="10"
  LEGACY_MODE=0
fi

if [[ -n "$WARMUP_RAW" ]]; then
  WARMUP="$WARMUP_RAW"
else
  WARMUP="3"
fi

declare -a entries
if [[ $# -eq 0 ]]; then
  entries=("bench/kpi_bench.vibe")
else
  entries=("$@")
fi

mkdir -p "$REPORT_DIR"

moon build --target native --release src/cmd/vibe >/dev/null

if [[ "$LEGACY_MODE" == "1" ]]; then
  bench_out="$("$CLI_BIN" bench --backend "$BACKEND" --n "$N" --warmup "$WARMUP" "${entries[@]}")"
else
  bench_out="$("$CLI_BIN" bench --backend "$BACKEND" --runs "$N" --warmup "$WARMUP" "${entries[@]}")"
fi
printf '%s\n' "$bench_out"

printf '%s\n' "$bench_out" | awk -v backend_name="$BACKEND" '
BEGIN {
  OFS = "\t"
  print "path", "name", "backend", "iterations", "elapsed_ms", "per_us", "wasm_bytes", "size_x_latency"
}
$0 ~ /^\[[^][]+\]$/ {
  path = $0
  sub(/^\[/, "", path)
  sub(/\]$/, "", path)
  next
}
/^[^:][^:]*: (ok|fail) \([0-9]+\/[0-9]+\)$/ {
  path = $0
  sub(/: .*/, "", path)
  next
}
/^  bench: / {
  line = $0
  name = line
  sub(/^.*bench: /, "", name)
  # strip first key=value onwards to get name
  sub(/ (count|runs)=.*/, "", name)

  # support both legacy (count=) and statistical (runs=) format
  iterations = "-1"
  if (line ~ /count=/) {
    iterations = line
    sub(/^.*count=/, "", iterations)
    sub(/ .*/, "", iterations)
  } else if (line ~ /runs=/) {
    iterations = line
    sub(/^.*runs=/, "", iterations)
    sub(/ .*/, "", iterations)
  }

  elapsed_ms = "-1"
  if (line ~ /total_ms=/) {
    elapsed_ms = line
    sub(/^.*total_ms=/, "", elapsed_ms)
    sub(/ .*/, "", elapsed_ms)
  }

  per_us = line
  sub(/^.*per_us=/, "", per_us)
  sub(/ .*/, "", per_us)

  wasm_bytes = "-1"
  if (line ~ /wasm_bytes=/) {
    wasm_bytes = line
    sub(/^.*wasm_bytes=/, "", wasm_bytes)
    sub(/ .*/, "", wasm_bytes)
  }

  score = "-1"
  if (wasm_bytes != "-1") {
    score = sprintf("%.6f", (wasm_bytes + 0) * (per_us + 0))
  }

  print path, name, backend_name, iterations, elapsed_ms, per_us, wasm_bytes, score
}
' > "$REPORT_FILE"

echo ""
echo "bench-kpi: wrote $REPORT_FILE"
echo ""
echo "[kpi summary]"
awk -F '\t' '
NR == 1 {
  next
}
{
  rows += 1
  sum_per_us += ($6 + 0)
  if (($7 + 0) >= 0) {
    wasm_rows += 1
    sum_wasm_bytes += ($7 + 0)
    sum_score += ($8 + 0)
  }
}
END {
  if (rows == 0) {
    print "cases=0"
    exit 0
  }
  printf "cases=%d avg_per_us=%.6f", rows, sum_per_us / rows
  if (wasm_rows > 0) {
    printf " avg_wasm_bytes=%.2f avg_size_x_latency=%.6f", sum_wasm_bytes / wasm_rows, sum_score / wasm_rows
  }
  printf "\n"
}
' "$REPORT_FILE"

if [[ "$BACKEND" == "wasm" ]]; then
  if awk -F '\t' 'NR > 1 && ($6 + 0) > 0 { found = 1 } END { exit found ? 1 : 0 }' "$REPORT_FILE"; then
    echo "bench-kpi: all per_us are 0; try larger N (e.g. VIBE_BENCH_KPI_N=200000)." >&2
  fi
fi

status=0

if [[ -n "$MAX_PER_US" ]]; then
  if ! awk -F '\t' -v limit="$MAX_PER_US" '
NR == 1 {
  next
}
($6 + 0) > limit {
  printf "bench-kpi: per_us regression: %s %s (got=%s, limit=%s)\n", $1, $2, $6, limit
  bad = 1
}
END {
  exit bad ? 1 : 0
}
' "$REPORT_FILE"; then
    status=1
  fi
fi

if [[ -n "$MAX_WASM_BYTES" ]]; then
  if ! awk -F '\t' -v limit="$MAX_WASM_BYTES" '
NR == 1 {
  next
}
($7 + 0) >= 0 && ($7 + 0) > limit {
  printf "bench-kpi: wasm size regression: %s %s (got=%s, limit=%s)\n", $1, $2, $7, limit
  bad = 1
}
END {
  exit bad ? 1 : 0
}
' "$REPORT_FILE"; then
    status=1
  fi
fi

if [[ -n "$MAX_SCORE" ]]; then
  if ! awk -F '\t' -v limit="$MAX_SCORE" '
NR == 1 {
  next
}
($8 + 0) >= 0 && ($8 + 0) > limit {
  printf "bench-kpi: score regression: %s %s (got=%s, limit=%s)\n", $1, $2, $8, limit
  bad = 1
}
END {
  exit bad ? 1 : 0
}
' "$REPORT_FILE"; then
    status=1
  fi
fi

if [[ -n "$MAX_PER_US" || -n "$MAX_WASM_BYTES" || -n "$MAX_SCORE" ]]; then
  if (( status != 0 )); then
    exit 1
  fi
  echo ""
  echo "bench-kpi: thresholds passed."
fi

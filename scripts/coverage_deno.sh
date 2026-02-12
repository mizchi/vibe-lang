#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUTPUT_DIR="${VIBE_DENO_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/deno}"
FILTER="${VIBE_DENO_COVERAGE_FILTER:-}"
MIN_LINE="${VIBE_DENO_COVERAGE_MIN_LINE:-}"

mkdir -p "$OUTPUT_DIR"
cd "$PROJECT_ROOT"

summary_file="$OUTPUT_DIR/summary.txt"
lcov_file="$OUTPUT_DIR/lcov.info"
html_dir="$OUTPUT_DIR/html"

echo "[deno coverage] build wasm artifact"
moon build --target wasm-gc --release src/lib

test_args=(deno test --allow-read "--coverage=$OUTPUT_DIR" --clean tests/integration-deno)
if [ -n "$FILTER" ]; then
  test_args+=(--filter "$FILTER")
fi

echo "[deno coverage] test: filter=${FILTER:-all}"
"${test_args[@]}"

echo "[deno coverage] summary -> $summary_file"
deno coverage "$OUTPUT_DIR" | tee "$summary_file"

echo "[deno coverage] lcov -> $lcov_file"
deno coverage --lcov --output="$lcov_file" "$OUTPUT_DIR" >/dev/null

if [ ! -f "$html_dir/index.html" ]; then
  echo "[deno coverage] warning: html report not found at $html_dir/index.html" >&2
fi

if [ -n "$MIN_LINE" ]; then
  all_files_line="$(grep '^| All files |' "$summary_file" | tail -n 1 || true)"
  if [ -z "$all_files_line" ]; then
    echo "[deno coverage] failed to parse All files line from summary" >&2
    exit 1
  fi
  line_pct="$(echo "$all_files_line" | awk -F'|' '{ gsub(/ /, "", $4); print $4 }')"
  if [ -z "$line_pct" ]; then
    echo "[deno coverage] failed to parse line coverage percent: $all_files_line" >&2
    exit 1
  fi
  line_pct_int="$(awk -v p="$line_pct" 'BEGIN { printf "%d", p + 0.5 }')"
  echo "[deno coverage] line=$line_pct% (min=${MIN_LINE}%)"
  if [ "$line_pct_int" -lt "$MIN_LINE" ]; then
    echo "[deno coverage] line coverage gate failed: $line_pct% < ${MIN_LINE}%" >&2
    exit 1
  fi
fi

echo "[deno coverage] reports:"
echo "  - $summary_file"
echo "  - $lcov_file"
echo "  - $html_dir/index.html"

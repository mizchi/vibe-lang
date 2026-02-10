#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUTPUT_DIR="${XSH_MOON_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/moon}"
TARGET="${XSH_MOON_COVERAGE_TARGET:-native}"
PACKAGE="${XSH_MOON_COVERAGE_PACKAGE:-}"
MIN_LINE="${XSH_MOON_COVERAGE_MIN_LINE:-}"

mkdir -p "$OUTPUT_DIR"
cd "$PROJECT_ROOT"

filter_known_noise() {
  local stderr_file="$1"
  if [ ! -s "$stderr_file" ]; then
    return 0
  fi
  if command -v rg >/dev/null 2>&1; then
    rg -v 'Warning scanning files: cannot read metadata of \./deps/wasmtime/tests/wasi_testsuite/.+fs-tests\.dir/parent' "$stderr_file" >&2 || true
  else
    grep -v 'Warning scanning files: cannot read metadata of ./deps/wasmtime/tests/wasi_testsuite/' "$stderr_file" >&2 || true
  fi
}

test_args=(moon test --target "$TARGET" --enable-coverage)
if [ -n "$PACKAGE" ]; then
  test_args+=(-p "$PACKAGE")
fi

echo "[moon coverage] clean"
moon coverage clean
echo "[moon coverage] test: target=$TARGET package=${PACKAGE:-all}"
"${test_args[@]}"

summary_file="$OUTPUT_DIR/summary.txt"
xml_file="$OUTPUT_DIR/moonbit-cobertura.xml"
html_dir="$OUTPUT_DIR/html"

stderr_file="$(mktemp "${TMPDIR:-/tmp}/xsh_moon_coverage.XXXXXX")"
trap 'rm -f "$stderr_file"' EXIT

summary_args=(moon coverage report --source-paths src -f summary)
common_args=(moon coverage report --source-paths src)
if [ -n "$PACKAGE" ]; then
  summary_args+=(-p "$PACKAGE")
  common_args+=(-p "$PACKAGE")
fi

echo "[moon coverage] summary -> $summary_file"
"${summary_args[@]}" 2>"$stderr_file" | tee "$summary_file"
filter_known_noise "$stderr_file"
: >"$stderr_file"

echo "[moon coverage] cobertura -> $xml_file"
"${common_args[@]}" -f cobertura -o "$xml_file" 2>"$stderr_file" >/dev/null
filter_known_noise "$stderr_file"
: >"$stderr_file"

echo "[moon coverage] html -> $html_dir"
"${common_args[@]}" -f html -o "$html_dir" 2>"$stderr_file" >/dev/null
filter_known_noise "$stderr_file"

if [ -n "$MIN_LINE" ]; then
  total_line="$(grep '^Total:' "$summary_file" | tail -n 1 || true)"
  if [ -z "$total_line" ]; then
    echo "[moon coverage] failed to parse Total line from summary" >&2
    exit 1
  fi
  covered="$(echo "$total_line" | sed -E 's/^Total: ([0-9]+)\/([0-9]+)$/\1/')"
  total="$(echo "$total_line" | sed -E 's/^Total: ([0-9]+)\/([0-9]+)$/\2/')"
  if [ -z "$covered" ] || [ -z "$total" ] || [ "$total" = "$total_line" ]; then
    echo "[moon coverage] failed to parse coverage counts: $total_line" >&2
    exit 1
  fi
  line_pct="$(awk -v c="$covered" -v t="$total" 'BEGIN { if (t == 0) { print "0.00" } else { printf "%.2f", (c * 100.0) / t } }')"
  line_pct_int="$(awk -v p="$line_pct" 'BEGIN { printf "%d", p + 0.5 }')"
  echo "[moon coverage] line=$line_pct% (min=${MIN_LINE}%)"
  if [ "$line_pct_int" -lt "$MIN_LINE" ]; then
    echo "[moon coverage] line coverage gate failed: $line_pct% < ${MIN_LINE}%" >&2
    exit 1
  fi
fi

echo "[moon coverage] reports:"
echo "  - $summary_file"
echo "  - $xml_file"
echo "  - $html_dir/index.html"

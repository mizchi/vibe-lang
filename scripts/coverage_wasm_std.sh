#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${XSH_WASM_STD_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/wasm-std}"
CASE_DIR="$OUT_DIR/cases"
REPORT_LIST="$OUT_DIR/reports.txt"
FAIL_LIST="$OUT_DIR/failures.txt"
SUMMARY_PATH="$OUT_DIR/summary.txt"
REPORT_JSON_PATH="$OUT_DIR/report.json"
STRICT="${XSH_WASM_STD_COVERAGE_STRICT:-0}"
NO_DCE="${XSH_WASM_STD_COVERAGE_NO_DCE:-0}"
MODE="${XSH_WASM_STD_COVERAGE_MODE:-wasm}"
FILTER="${XSH_WASM_STD_COVERAGE_FILTER:-}"
EXCLUDE="${XSH_WASM_STD_COVERAGE_EXCLUDE:-}"

case "$STRICT" in
  0|1) ;;
  *)
    echo "[wasm std coverage] invalid strict flag: $STRICT (expected: 0|1)" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"
mkdir -p "$CASE_DIR"
: > "$REPORT_LIST"
: > "$FAIL_LIST"

cd "$PROJECT_ROOT"

mapfile -t tests < <(find xsh/std -name '*_test.xsh' | sort)
if [ -n "$FILTER" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg "$FILTER" || true)
fi
if [ -n "$EXCLUDE" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg -v "$EXCLUDE" || true)
fi
if [ "${#tests[@]}" -eq 0 ]; then
  echo "[wasm std coverage] no test files selected under xsh/std" >&2
  exit 1
fi

echo "[wasm std coverage] cases=${#tests[@]} mode=$MODE no_dce=$NO_DCE"

for entry in "${tests[@]}"; do
  echo "[wasm std coverage] case: $entry"
  if XSH_WASM_SOURCE_COVERAGE_DIR="$CASE_DIR" \
    XSH_WASM_SOURCE_COVERAGE_MODE="$MODE" \
    XSH_WASM_SOURCE_COVERAGE_NO_DCE="$NO_DCE" \
    XSH_WASM_SOURCE_COVERAGE_RUN_TESTS=1 \
    "$SCRIPT_DIR/coverage_wasm_source.sh" "$entry"; then
    entry_norm="${entry#./}"
    entry_stem="${entry_norm%.*}"
    entry_slug="${entry_stem//\//__}"
    report_path="$CASE_DIR/$entry_slug.report.json"
    if [ -f "$report_path" ]; then
      echo "$report_path" >> "$REPORT_LIST"
    else
      echo "$entry" >> "$FAIL_LIST"
      echo "[wasm std coverage] missing report: $report_path" >&2
    fi
  else
    echo "$entry" >> "$FAIL_LIST"
  fi
done

if [ ! -s "$REPORT_LIST" ]; then
  echo "[wasm std coverage] no successful coverage reports" >&2
  exit 1
fi

node "$SCRIPT_DIR/coverage_wasm_std.mjs" \
  "$REPORT_LIST" \
  --json "$REPORT_JSON_PATH" \
  --summary "$SUMMARY_PATH" \
  --failures "$FAIL_LIST" \
  --total "${#tests[@]}"

echo "[wasm std coverage] reports:"
echo "  - $SUMMARY_PATH"
echo "  - $REPORT_JSON_PATH"
echo "  - $REPORT_LIST"
if [ -s "$FAIL_LIST" ]; then
  echo "  - $FAIL_LIST"
fi

if [ "$STRICT" = "1" ] && [ -s "$FAIL_LIST" ]; then
  echo "[wasm std coverage] failed cases detected (strict=1)" >&2
  exit 1
fi

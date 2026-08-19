#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_WASM_STD_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/wasm-std}"
CASE_DIR="$OUT_DIR/cases"
REPORT_LIST="$OUT_DIR/reports.txt"
FAIL_LIST="$OUT_DIR/failures.txt"
ATTEMPT_LIST="$OUT_DIR/attempts.tsv"
SUMMARY_PATH="$OUT_DIR/summary.txt"
REPORT_JSON_PATH="$OUT_DIR/report.json"
REPORT_MD_PATH="$OUT_DIR/report.md"
STRICT="${VIBE_WASM_STD_COVERAGE_STRICT:-0}"
NO_DCE="${VIBE_WASM_STD_COVERAGE_NO_DCE:-0}"
MODE_SINGLE="${VIBE_WASM_STD_COVERAGE_MODE:-}"
MODES_RAW="${VIBE_WASM_STD_COVERAGE_MODES:-}"
FILTER="${VIBE_WASM_STD_COVERAGE_FILTER:-}"
EXCLUDE="${VIBE_WASM_STD_COVERAGE_EXCLUDE:-}"
ALLOW_TRAP="${VIBE_WASM_STD_COVERAGE_ALLOW_TRAP:-1}"
MIN_MEASURED_RATE="${VIBE_WASM_STD_COVERAGE_MIN_MEASURED_RATE:-}"
MIN_LINE_RATE="${VIBE_WASM_STD_COVERAGE_MIN_LINE_RATE:-}"
MATRIX_PATH="${VIBE_WASM_STD_COVERAGE_MATRIX:-$PROJECT_ROOT/lib/@vibe/builtin/backend_capabilities.json}"

case "$STRICT" in
  0|1) ;;
  *)
    echo "[wasm std coverage] invalid strict flag: $STRICT (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$ALLOW_TRAP" in
  0|1) ;;
  *)
    echo "[wasm std coverage] invalid allow-trap flag: $ALLOW_TRAP (expected: 0|1)" >&2
    exit 1
    ;;
esac

modes=()
if [ -n "$MODES_RAW" ]; then
  normalized_modes="$(echo "$MODES_RAW" | tr ',' ' ')"
  for token in $normalized_modes; do
    modes+=("$token")
  done
elif [ -n "$MODE_SINGLE" ]; then
  modes=("$MODE_SINGLE")
else
  modes=("wasm" "wasm-js-string")
fi

if [ "${#modes[@]}" -eq 0 ]; then
  echo "[wasm std coverage] no coverage modes configured" >&2
  exit 1
fi

for mode in "${modes[@]}"; do
  case "$mode" in
    wasm|wasm-js-string) ;;
    *)
      echo "[wasm std coverage] invalid mode: $mode (expected: wasm|wasm-js-string)" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$OUT_DIR"
mkdir -p "$CASE_DIR"
: > "$REPORT_LIST"
: > "$FAIL_LIST"
: > "$ATTEMPT_LIST"

cd "$PROJECT_ROOT"

mapfile -t tests < <(find lib/@vibe/builtin -name '*_test.vibe' | sort)
if [ -n "$FILTER" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg "$FILTER" || true)
fi
if [ -n "$EXCLUDE" ]; then
  mapfile -t tests < <(printf '%s\n' "${tests[@]}" | rg -v "$EXCLUDE" || true)
fi
if [ "${#tests[@]}" -eq 0 ]; then
  echo "[wasm std coverage] no test files selected under lib/@vibe/builtin" >&2
  exit 1
fi

echo "[wasm std coverage] cases=${#tests[@]} modes=${modes[*]} no_dce=$NO_DCE allow_trap=$ALLOW_TRAP"

for entry in "${tests[@]}"; do
  echo "[wasm std coverage] case: $entry"
  entry_norm="${entry#./}"
  entry_stem="${entry_norm%.*}"
  entry_slug="${entry_stem//\//__}"
  report_path="$CASE_DIR/$entry_slug.report.json"
  case_ok=0

  for mode in "${modes[@]}"; do
    log_path="$CASE_DIR/$entry_slug.$mode.log"
    if VIBE_WASM_SOURCE_COVERAGE_DIR="$CASE_DIR" \
      VIBE_WASM_SOURCE_COVERAGE_MODE="$mode" \
      VIBE_WASM_SOURCE_COVERAGE_NO_DCE="$NO_DCE" \
      VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=1 \
      VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP="$ALLOW_TRAP" \
      "$SCRIPT_DIR/coverage_wasm_source.sh" "$entry" >"$log_path" 2>&1; then
      printf '%s\t%s\t0\t%s\t%s\n' "$entry" "$mode" "$log_path" "$report_path" >> "$ATTEMPT_LIST"
      if [ -f "$report_path" ]; then
        echo "$report_path" >> "$REPORT_LIST"
        case_ok=1
        break
      fi
      printf '%s\t%s\t2\t%s\t-\n' "$entry" "$mode" "$log_path" >> "$ATTEMPT_LIST"
    else
      code=$?
      printf '%s\t%s\t%d\t%s\t-\n' "$entry" "$mode" "$code" "$log_path" >> "$ATTEMPT_LIST"
    fi
  done

  if [ "$case_ok" -ne 1 ]; then
    echo "$entry" >> "$FAIL_LIST"
  fi
done

node_args=(
  "$SCRIPT_DIR/coverage_wasm_std.mjs"
  "$REPORT_LIST"
  --json "$REPORT_JSON_PATH"
  --summary "$SUMMARY_PATH"
  --markdown "$REPORT_MD_PATH"
  --failures "$FAIL_LIST"
  --attempts "$ATTEMPT_LIST"
  --total "${#tests[@]}"
  --strict "$STRICT"
)
if [ -f "$MATRIX_PATH" ]; then
  node_args+=(--matrix "$MATRIX_PATH")
fi
if [ -n "$MIN_MEASURED_RATE" ]; then
  node_args+=(--min-measured-rate "$MIN_MEASURED_RATE")
fi
if [ -n "$MIN_LINE_RATE" ]; then
  node_args+=(--min-line-rate "$MIN_LINE_RATE")
fi
node "${node_args[@]}"

echo "[wasm std coverage] reports:"
echo "  - $SUMMARY_PATH"
echo "  - $REPORT_JSON_PATH"
echo "  - $REPORT_MD_PATH"
echo "  - $REPORT_LIST"
echo "  - $ATTEMPT_LIST"
if [ -s "$FAIL_LIST" ]; then
  echo "  - $FAIL_LIST"
fi

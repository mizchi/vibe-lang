#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_WASM_SOURCE_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/wasm-source}"
MODE="${VIBE_WASM_SOURCE_COVERAGE_MODE:-wasm}"
NO_DCE="${VIBE_WASM_SOURCE_COVERAGE_NO_DCE:-0}"
RUN_TESTS="${VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS:-0}"
ALLOW_TRAP="${VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP:-0}"
INVOKE_EXPORTS="${VIBE_WASM_SOURCE_COVERAGE_INVOKE:-}"
MIN_POINT_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE:-}"
MIN_LINE_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE:-}"
MIN_BRANCH_RATE="${VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE:-}"

if [ "$#" -lt 1 ]; then
  echo "usage: coverage_wasm_source.sh <entry.vibe>" >&2
  echo "env: VIBE_WASM_SOURCE_COVERAGE_MODE=wasm|wasm-js-string VIBE_WASM_SOURCE_COVERAGE_NO_DCE=0|1 VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS=0|1 VIBE_WASM_SOURCE_COVERAGE_ALLOW_TRAP=0|1 VIBE_WASM_SOURCE_COVERAGE_INVOKE=<export[,export...]> VIBE_WASM_SOURCE_COVERAGE_MIN_POINT_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_MIN_LINE_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_MIN_BRANCH_RATE=<0-100> VIBE_WASM_SOURCE_COVERAGE_DIR=<dir>" >&2
  exit 1
fi

ENTRY_PATH="$1"
if [ ! -f "$ENTRY_PATH" ]; then
  echo "[wasm source coverage] entry not found: $ENTRY_PATH" >&2
  exit 1
fi

case "$MODE" in
  wasm|wasm-js-string) ;;
  *)
    echo "[wasm source coverage] invalid mode: $MODE (expected: wasm|wasm-js-string)" >&2
    exit 1
    ;;
esac

case "$RUN_TESTS" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid run-tests flag: $RUN_TESTS (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$ALLOW_TRAP" in
  0|1) ;;
  *)
    echo "[wasm source coverage] invalid allow-trap flag: $ALLOW_TRAP (expected: 0|1)" >&2
    exit 1
    ;;
esac

mkdir -p "$OUT_DIR"
cd "$PROJECT_ROOT"

entry_norm="${ENTRY_PATH#./}"
if [[ "$entry_norm" == "$PROJECT_ROOT/"* ]]; then
  entry_norm="${entry_norm#$PROJECT_ROOT/}"
fi
entry_stem="${entry_norm%.*}"
entry_slug="${entry_stem//\//__}"
wasm_path="$OUT_DIR/$entry_slug.wasm"
cov_map_path="$wasm_path.cov.json"
report_json_path="$OUT_DIR/$entry_slug.report.json"
summary_path="$OUT_DIR/$entry_slug.summary.txt"

compile_args=(compile "--$MODE" --coverage -o "$wasm_path" "$ENTRY_PATH")
if [ "$NO_DCE" = "1" ]; then
  compile_args=(compile "--$MODE" --no-dce --coverage -o "$wasm_path" "$ENTRY_PATH")
fi
if [ "$RUN_TESTS" = "1" ]; then
  compile_args=(compile "--$MODE" --coverage --coverage-run-tests -o "$wasm_path" "$ENTRY_PATH")
  if [ "$NO_DCE" = "1" ]; then
    compile_args=(compile "--$MODE" --no-dce --coverage --coverage-run-tests -o "$wasm_path" "$ENTRY_PATH")
  fi
fi

echo "[wasm source coverage] compile: mode=$MODE no_dce=$NO_DCE run_tests=$RUN_TESTS allow_trap=$ALLOW_TRAP entry=$ENTRY_PATH"
VIBE_TEST_COVERAGE=1 moon run src/cmd/vibe/main.mbt --target native -- "${compile_args[@]}"

if [ ! -f "$cov_map_path" ]; then
  echo "[wasm source coverage] missing coverage map: $cov_map_path" >&2
  exit 1
fi

echo "[wasm source coverage] execute + collect"
node_runner_cmd=(node)
if command -v node >/dev/null 2>&1; then
  if node --experimental-wasm-exnref -e "" >/dev/null 2>&1; then
    node_runner_cmd+=(--experimental-wasm-exnref)
  fi
fi
node_args=(
  "$SCRIPT_DIR/coverage_wasm_source.mjs"
  "$wasm_path"
  "$cov_map_path"
  --json "$report_json_path"
  --summary "$summary_path"
)
if [ "$ALLOW_TRAP" = "1" ]; then
  node_args+=(--allow-trap)
fi
if [ -n "$INVOKE_EXPORTS" ]; then
  IFS=',' read -r -a invoke_list <<< "$INVOKE_EXPORTS"
  for invoke_name in "${invoke_list[@]}"; do
    trimmed="${invoke_name#"${invoke_name%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -n "$trimmed" ]; then
      node_args+=(--invoke "$trimmed")
    fi
  done
fi
if [ -n "$MIN_POINT_RATE" ]; then
  node_args+=(--min-point-rate "$MIN_POINT_RATE")
fi
if [ -n "$MIN_LINE_RATE" ]; then
  node_args+=(--min-line-rate "$MIN_LINE_RATE")
fi
if [ -n "$MIN_BRANCH_RATE" ]; then
  node_args+=(--min-branch-rate "$MIN_BRANCH_RATE")
fi
"${node_runner_cmd[@]}" "${node_args[@]}"

echo "[wasm source coverage] reports:"
echo "  - $summary_path"
echo "  - $report_json_path"
echo "  - $cov_map_path"

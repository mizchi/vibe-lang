#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_SELFHOST_SUITE_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/selfhost-suite}"
SOURCE_OUT_DIR="${VIBE_SELFHOST_SUITE_SOURCE_DIR:-$OUT_DIR/wasm-source}"
SELFHOST_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_SELFHOST:-vibe/compiler/selfhost_coverage_run.vibe}"
INDEX_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_INDEX:-vibe/compiler/index.vibe}"
INDEX_INVOKE="${VIBE_SELFHOST_SUITE_INDEX_INVOKE:-selfbuild_compile_stage2}"
EXTRA_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_EXTRA:-vibe/compiler/eval_e2e_test.vibe}"
EXTRA_RUN_TESTS="${VIBE_SELFHOST_SUITE_ENTRY_EXTRA_RUN_TESTS:-1}"
MIN_POINT_RATE="${VIBE_SELFHOST_SUITE_MIN_POINT_RATE:-}"
MIN_LINE_RATE="${VIBE_SELFHOST_SUITE_MIN_LINE_RATE:-}"
MIN_BRANCH_RATE="${VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE:-}"

entry_slug() {
  local entry="$1"
  local norm="${entry#./}"
  if [[ "$norm" == "$PROJECT_ROOT/"* ]]; then
    norm="${norm#$PROJECT_ROOT/}"
  fi
  local stem="${norm%.*}"
  echo "${stem//\//__}"
}

report_path_for_entry() {
  local entry="$1"
  local slug
  slug="$(entry_slug "$entry")"
  echo "$SOURCE_OUT_DIR/$slug.report.json"
}

mkdir -p "$OUT_DIR" "$SOURCE_OUT_DIR"
cd "$PROJECT_ROOT"

case "$EXTRA_RUN_TESTS" in
  0|1) ;;
  *)
    echo "[selfhost suite coverage] invalid extra run-tests flag: $EXTRA_RUN_TESTS (expected: 0|1)" >&2
    exit 1
    ;;
esac

echo "[selfhost suite coverage] collect: $SELFHOST_ENTRY"
VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
  "$SCRIPT_DIR/coverage_wasm_source.sh" "$SELFHOST_ENTRY"

echo "[selfhost suite coverage] collect: $INDEX_ENTRY (invoke=$INDEX_INVOKE)"
VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
  VIBE_WASM_SOURCE_COVERAGE_INVOKE="$INDEX_INVOKE" \
  "$SCRIPT_DIR/coverage_wasm_source.sh" "$INDEX_ENTRY"

if [ -n "$EXTRA_ENTRY" ]; then
  echo "[selfhost suite coverage] collect: $EXTRA_ENTRY (run_tests=$EXTRA_RUN_TESTS)"
  VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
    VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS="$EXTRA_RUN_TESTS" \
    "$SCRIPT_DIR/coverage_wasm_source.sh" "$EXTRA_ENTRY"
fi

report_list_path="$OUT_DIR/reports.txt"
report_json_path="$OUT_DIR/selfhost_suite.report.json"
summary_path="$OUT_DIR/selfhost_suite.summary.txt"

report_paths=(
  "$(report_path_for_entry "$SELFHOST_ENTRY")"
  "$(report_path_for_entry "$INDEX_ENTRY")"
)
if [ -n "$EXTRA_ENTRY" ]; then
  report_paths+=("$(report_path_for_entry "$EXTRA_ENTRY")")
fi
printf "%s\n" "${report_paths[@]}" >"$report_list_path"

node_args=(
  "$SCRIPT_DIR/coverage_selfhost_suite.mjs"
  "$report_list_path"
  --json "$report_json_path"
  --summary "$summary_path"
)
if [ -n "$MIN_POINT_RATE" ]; then
  node_args+=(--min-point-rate "$MIN_POINT_RATE")
fi
if [ -n "$MIN_LINE_RATE" ]; then
  node_args+=(--min-line-rate "$MIN_LINE_RATE")
fi
if [ -n "$MIN_BRANCH_RATE" ]; then
  node_args+=(--min-branch-rate "$MIN_BRANCH_RATE")
fi
node "${node_args[@]}"

echo "[selfhost suite coverage] reports:"
echo "  - $summary_path"
echo "  - $report_json_path"
echo "  - $report_list_path"

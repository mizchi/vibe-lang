#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_SELFHOST_SUITE_COVERAGE_DIR:-$PROJECT_ROOT/_build/coverage/selfhost-suite}"
SOURCE_OUT_DIR="${VIBE_SELFHOST_SUITE_SOURCE_DIR:-$OUT_DIR/wasm-source}"
SELFHOST_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_SELFHOST:-vibe/compiler/selfhost_coverage_run.vibe}"
INDEX_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_INDEX:-vibe/compiler/selfhost_stage2_coverage_run.vibe}"
INDEX_INVOKE="${VIBE_SELFHOST_SUITE_INDEX_INVOKE:-}"
EXTRA_ENTRIES="${VIBE_SELFHOST_SUITE_EXTRA_ENTRIES:-vibe/compiler/eval_e2e_test.vibe,vibe/compiler/fixture_test.vibe,vibe/compiler/eval_selfhost_test.vibe,vibe/compiler/eval_selfhost2_test.vibe,vibe/compiler/eval_selfhost3_test.vibe}"
LEGACY_EXTRA_ENTRY="${VIBE_SELFHOST_SUITE_ENTRY_EXTRA:-}"
EXTRA_RUN_TESTS="${VIBE_SELFHOST_SUITE_ENTRY_EXTRA_RUN_TESTS:-1}"
MIN_POINT_RATE="${VIBE_SELFHOST_SUITE_MIN_POINT_RATE:-}"
MIN_LINE_RATE="${VIBE_SELFHOST_SUITE_MIN_LINE_RATE:-}"
MIN_BRANCH_RATE="${VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE:-}"
TEST_BACKEND="${VIBE_SELFHOST_SUITE_TEST_BACKEND:-compiled}"

resolve_vibe_cmd() {
  local candidates=()
  if [ -n "${VIBE_BIN:-}" ] && [ -x "$VIBE_BIN" ]; then
    VIBE_CMD=("$VIBE_BIN")
    return 0
  fi
  candidates+=(
    "$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe"
    "$PROJECT_ROOT/target/native/debug/build/cmd/vibe/vibe.exe"
  )
  for candidate in "${candidates[@]}"; do
    if [ ! -x "$candidate" ]; then
      continue
    fi
    if [ "$PROJECT_ROOT/moon.mod.json" -nt "$candidate" ]; then
      continue
    fi
    if find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$candidate" -print -quit 2>/dev/null | grep -q .; then
      continue
    fi
    VIBE_CMD=("$candidate")
    return 0
  done
  VIBE_CMD=(moon run src/cmd/vibe/main.mbt --target native --)
}

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
resolve_vibe_cmd

case "$EXTRA_RUN_TESTS" in
  0|1) ;;
  *)
    echo "[selfhost suite coverage] invalid extra run-tests flag: $EXTRA_RUN_TESTS (expected: 0|1)" >&2
    exit 1
    ;;
esac

case "$TEST_BACKEND" in
  compiled|interpreter|auto) ;;
  *)
    echo "[selfhost suite coverage] invalid test backend: $TEST_BACKEND (expected: compiled|interpreter|auto)" >&2
    exit 1
    ;;
esac

extra_entries=()
append_unique_entry() {
  local candidate="$1"
  for existing in "${extra_entries[@]-}"; do
    if [ "$existing" = "$candidate" ]; then
      return 0
    fi
  done
  extra_entries+=("$candidate")
}
if [ -n "$EXTRA_ENTRIES" ]; then
  IFS=',' read -r -a extra_raw_entries <<< "$EXTRA_ENTRIES"
  for raw_entry in "${extra_raw_entries[@]}"; do
    trimmed="${raw_entry#"${raw_entry%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [ -n "$trimmed" ]; then
      append_unique_entry "$trimmed"
    fi
  done
fi
if [ -n "$LEGACY_EXTRA_ENTRY" ]; then
  append_unique_entry "$LEGACY_EXTRA_ENTRY"
fi

echo "[selfhost suite coverage] collect: $SELFHOST_ENTRY"
VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
  "$SCRIPT_DIR/coverage_wasm_source.sh" "$SELFHOST_ENTRY"

if [ -n "$INDEX_INVOKE" ]; then
  echo "[selfhost suite coverage] collect: $INDEX_ENTRY (invoke=$INDEX_INVOKE)"
  VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
    VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY=1 \
    VIBE_WASM_SOURCE_COVERAGE_INVOKE="$INDEX_INVOKE" \
    "$SCRIPT_DIR/coverage_wasm_source.sh" "$INDEX_ENTRY"
else
  echo "[selfhost suite coverage] collect: $INDEX_ENTRY"
  VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
    VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY=1 \
    "$SCRIPT_DIR/coverage_wasm_source.sh" "$INDEX_ENTRY"
fi

for extra_entry in "${extra_entries[@]-}"; do
  echo "[selfhost suite coverage] collect: $extra_entry (run_tests=$EXTRA_RUN_TESTS)"
  VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
    VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS="$EXTRA_RUN_TESTS" \
    "$SCRIPT_DIR/coverage_wasm_source.sh" "$extra_entry"
done

report_list_path="$OUT_DIR/reports.txt"
report_json_path="$OUT_DIR/selfhost_suite.report.json"
summary_path="$OUT_DIR/selfhost_suite.summary.txt"

report_paths=(
  "$(report_path_for_entry "$SELFHOST_ENTRY")"
  "$(report_path_for_entry "$INDEX_ENTRY")"
)
for extra_entry in "${extra_entries[@]-}"; do
  report_paths+=("$(report_path_for_entry "$extra_entry")")
done
printf "%s\n" "${report_paths[@]}" >"$report_list_path"

VIBE_TEST_BACKEND="$TEST_BACKEND" \
  VIBE_SELFHOST_SUITE_REPORT_LIST="$report_list_path" \
  VIBE_SELFHOST_SUITE_REPORT_JSON="$report_json_path" \
  VIBE_SELFHOST_SUITE_SUMMARY="$summary_path" \
  VIBE_SELFHOST_SUITE_MIN_POINT_RATE="$MIN_POINT_RATE" \
  VIBE_SELFHOST_SUITE_MIN_LINE_RATE="$MIN_LINE_RATE" \
  VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE="$MIN_BRANCH_RATE" \
  "${VIBE_CMD[@]}" test vibe/compiler/coverage_selfhost_suite_run.vibe

echo "[selfhost suite coverage] reports:"
echo "  - $summary_path"
echo "  - $report_json_path"
echo "  - $report_list_path"

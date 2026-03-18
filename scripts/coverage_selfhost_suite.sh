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
COLLECT_JOBS="${VIBE_SELFHOST_SUITE_COLLECT_JOBS:-}"
REUSE_SUITE_CACHE="${VIBE_SELFHOST_SUITE_REUSE_CACHE:-1}"

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

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

is_positive_int() {
  if ! is_non_negative_int "$1"; then
    return 1
  fi
  [ "$1" -gt 0 ]
}

detect_default_collect_jobs() {
  local cpus
  cpus=""
  if command -v nproc >/dev/null 2>&1; then
    cpus="$(nproc || true)"
  elif command -v sysctl >/dev/null 2>&1; then
    cpus="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if ! is_positive_int "${cpus:-}"; then
    cpus=2
  fi
  if [ "$cpus" -gt 4 ]; then
    cpus=4
  fi
  if [ "$cpus" -lt 1 ]; then
    cpus=1
  fi
  echo "$cpus"
}

cache_key_equals() {
  local path="$1"
  local expected="$2"
  if [ ! -f "$path" ]; then
    return 1
  fi
  [ "$(cat "$path")" = "$expected" ]
}

build_suite_cache_key() {
  SUITE_CACHE_SOURCE_FILES="$PROJECT_ROOT/vibe/compiler/coverage_selfhost_suite_run.vibe,$PROJECT_ROOT/vibe/compiler/coverage_selfhost_suite_lib.vibe" \
    SUITE_CACHE_TEST_BACKEND="$TEST_BACKEND" \
    SUITE_CACHE_MIN_POINT_RATE="$MIN_POINT_RATE" \
    SUITE_CACHE_MIN_LINE_RATE="$MIN_LINE_RATE" \
    SUITE_CACHE_MIN_BRANCH_RATE="$MIN_BRANCH_RATE" \
    node - "$report_list_path" <<'NODE'
const fs = require("node:fs");

const reportListPath = process.argv[2];
const listContent = fs.readFileSync(reportListPath, "utf8");
const reportPaths = listContent.split(/\r?\n/).filter(Boolean);
const sourceFiles = (process.env.SUITE_CACHE_SOURCE_FILES || "")
  .split(",")
  .filter(Boolean);

function statLine(filePath) {
  const stat = fs.statSync(filePath);
  return `${filePath}\t${stat.mtimeMs}\t${stat.size}`;
}

const lines = [
  `test_backend=${process.env.SUITE_CACHE_TEST_BACKEND || ""}`,
  `min_point_rate=${process.env.SUITE_CACHE_MIN_POINT_RATE || ""}`,
  `min_line_rate=${process.env.SUITE_CACHE_MIN_LINE_RATE || ""}`,
  `min_branch_rate=${process.env.SUITE_CACHE_MIN_BRANCH_RATE || ""}`,
  `report_list=${listContent.trim()}`,
];

for (const filePath of [...reportPaths, ...sourceFiles]) {
  lines.push(statLine(filePath));
}

process.stdout.write(lines.join("\n"));
NODE
}

suite_cache_valid() {
  if [ "$REUSE_SUITE_CACHE" != "1" ]; then
    return 1
  fi
  if [ ! -f "$summary_path" ] || [ ! -f "$report_json_path" ] || [ ! -f "$suite_meta_path" ] || [ ! -f "$suite_status_path" ]; then
    return 1
  fi
  cache_key_equals "$suite_meta_path" "$suite_cache_key"
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
if [ -z "$COLLECT_JOBS" ]; then
  COLLECT_JOBS="$(detect_default_collect_jobs)"
fi

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

case "$REUSE_SUITE_CACHE" in
  0|1) ;;
  *)
    echo "[selfhost suite coverage] invalid suite cache flag: $REUSE_SUITE_CACHE (expected: 0|1)" >&2
    exit 1
    ;;
esac

if ! is_positive_int "$COLLECT_JOBS"; then
  echo "[selfhost suite coverage] invalid collect jobs: $COLLECT_JOBS (expected positive int)" >&2
  exit 1
fi

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

collect_labels=()
collect_entries=()
collect_summary_only=()
collect_invokes=()
collect_run_tests=()

append_collect_task() {
  collect_labels+=("$1")
  collect_entries+=("$2")
  collect_summary_only+=("$3")
  collect_invokes+=("$4")
  collect_run_tests+=("$5")
}

run_collect_task() {
  local idx="$1"
  local label="${collect_labels[$idx]}"
  local entry="${collect_entries[$idx]}"
  local summary_only="${collect_summary_only[$idx]}"
  local invoke_name="${collect_invokes[$idx]}"
  local run_tests="${collect_run_tests[$idx]}"
  echo "[selfhost suite coverage] collect: $label"
  if [ -n "$invoke_name" ]; then
    VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
      VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY="$summary_only" \
      VIBE_WASM_SOURCE_COVERAGE_INVOKE="$invoke_name" \
      VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS="$run_tests" \
      "$SCRIPT_DIR/coverage_wasm_source.sh" "$entry"
  else
    VIBE_WASM_SOURCE_COVERAGE_DIR="$SOURCE_OUT_DIR" \
      VIBE_WASM_SOURCE_COVERAGE_REPORT_SUMMARY_ONLY="$summary_only" \
      VIBE_WASM_SOURCE_COVERAGE_RUN_TESTS="$run_tests" \
      "$SCRIPT_DIR/coverage_wasm_source.sh" "$entry"
  fi
}

append_collect_task "$SELFHOST_ENTRY" "$SELFHOST_ENTRY" 0 "" 0
if [ -n "$INDEX_INVOKE" ]; then
  append_collect_task "$INDEX_ENTRY (invoke=$INDEX_INVOKE)" "$INDEX_ENTRY" 1 "$INDEX_INVOKE" 0
else
  append_collect_task "$INDEX_ENTRY" "$INDEX_ENTRY" 1 "" 0
fi
for extra_entry in "${extra_entries[@]-}"; do
  append_collect_task "$extra_entry (run_tests=$EXTRA_RUN_TESTS)" "$extra_entry" 0 "" "$EXTRA_RUN_TESTS"
done

collect_log_dir="$OUT_DIR/.collect-logs"
rm -rf "$collect_log_dir"
mkdir -p "$collect_log_dir"
cleanup_collect_logs() {
  rm -rf "$collect_log_dir"
}
trap cleanup_collect_logs EXIT

run_collect_batch() {
  local start="$1"
  local end="$2"
  local pids=()
  local logs=()
  local i
  for ((i = start; i < end; i++)); do
    local log_path="$collect_log_dir/$i.log"
    logs+=("$log_path")
    run_collect_task "$i" >"$log_path" 2>&1 &
    pids+=("$!")
  done

  local failed=0
  for ((i = 0; i < ${#pids[@]}; i++)); do
    local wait_status=0
    wait "${pids[$i]}" || wait_status="$?"
    if [ "$wait_status" -ne 0 ]; then
      failed=$((failed + 1))
      local fail_idx=$((start + i))
      echo "[selfhost suite coverage] collect FAILED (exit $wait_status): ${collect_labels[$fail_idx]}" >&2
    fi
    cat "${logs[$i]}"
  done
  if [ "$failed" -gt 0 ]; then
    echo "[selfhost suite coverage] $failed task(s) failed in batch, continuing..." >&2
  fi
}

task_count="${#collect_entries[@]}"
task_start=0
while [ "$task_start" -lt "$task_count" ]; do
  task_end=$((task_start + COLLECT_JOBS))
  if [ "$task_end" -gt "$task_count" ]; then
    task_end="$task_count"
  fi
  run_collect_batch "$task_start" "$task_end"
  task_start="$task_end"
done

report_list_path="$OUT_DIR/reports.txt"
report_json_path="$OUT_DIR/selfhost_suite.report.json"
summary_path="$OUT_DIR/selfhost_suite.summary.txt"
suite_meta_path="$OUT_DIR/selfhost_suite.meta"
suite_status_path="$OUT_DIR/selfhost_suite.status"
suite_log_path="$OUT_DIR/selfhost_suite.log"

report_paths=()
collect_skipped=0
for candidate_entry in "$SELFHOST_ENTRY" "$INDEX_ENTRY" "${extra_entries[@]-}"; do
  rp="$(report_path_for_entry "$candidate_entry")"
  if [ -f "$rp" ]; then
    report_paths+=("$rp")
  else
    echo "[selfhost suite coverage] skipping missing report: $rp (entry=$candidate_entry)" >&2
    collect_skipped=$((collect_skipped + 1))
  fi
done
if [ "${#report_paths[@]}" -eq 0 ]; then
  echo "[selfhost suite coverage] no reports collected, aborting" >&2
  exit 1
fi
if [ "$collect_skipped" -gt 0 ]; then
  echo "[selfhost suite coverage] $collect_skipped report(s) skipped due to collection failures" >&2
fi
printf "%s\n" "${report_paths[@]}" >"$report_list_path"

suite_cache_key="$(build_suite_cache_key)"

if suite_cache_valid; then
  echo "[selfhost suite coverage] reuse suite aggregate cache"
  cat "$summary_path"
  suite_status="$(cat "$suite_status_path")"
  if [ "$suite_status" != "0" ]; then
    if [ -f "$suite_log_path" ]; then
      cat "$suite_log_path" >&2
    fi
    exit "$suite_status"
  fi
else
  set +e
  VIBE_TEST_BACKEND="$TEST_BACKEND" \
    VIBE_SELFHOST_SUITE_REPORT_LIST="$report_list_path" \
    VIBE_SELFHOST_SUITE_REPORT_JSON="$report_json_path" \
    VIBE_SELFHOST_SUITE_SUMMARY="$summary_path" \
    VIBE_SELFHOST_SUITE_MIN_POINT_RATE="$MIN_POINT_RATE" \
    VIBE_SELFHOST_SUITE_MIN_LINE_RATE="$MIN_LINE_RATE" \
    VIBE_SELFHOST_SUITE_MIN_BRANCH_RATE="$MIN_BRANCH_RATE" \
    "${VIBE_CMD[@]}" test vibe/compiler/coverage_selfhost_suite_run.vibe >"$suite_log_path" 2>&1
  suite_status="$?"
  set -e
  cat "$suite_log_path"
  printf '%s' "$suite_cache_key" >"$suite_meta_path"
  printf '%s' "$suite_status" >"$suite_status_path"
  if [ "$suite_status" != "0" ]; then
    exit "$suite_status"
  fi
fi

echo "[selfhost suite coverage] reports:"
echo "  - $summary_path"
echo "  - $report_json_path"
echo "  - $report_list_path"

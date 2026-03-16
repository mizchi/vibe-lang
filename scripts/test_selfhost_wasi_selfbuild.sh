#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE1_COMPILER_WASM="${STAGE1_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"
STAGE1_WASM="$OUT_DIR/index_stage1.wasm"
STAGE2_WASM="$OUT_DIR/index_stage2.wasm"
DEFAULT_OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_wasi_selfbuild"
DEFAULT_ENTRY_PATH="$PROJECT_ROOT/vibe/compiler/index.vibe"
VIBE_HOST_RUNNER="${VIBE_SELFHOST_WASM_VIBE_HOST_RUNNER:-$PROJECT_ROOT/scripts/wasm_vibe_host_runner.js}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_SELFBUILD_STAGE_TIMEOUT_SEC:-600}"
STRICT_RECURSIVE="${VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE:-0}"
REQUIRE_TRUE_RECURSIVE="${VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE:-0}"
SELFBUILD_MAX_TOTAL_SEC="${VIBE_SELFHOST_SELFBUILD_MAX_TOTAL_SEC:-0}"

run_with_timeout() {
  local timeout_sec="$1"
  shift
  if [ "$timeout_sec" -le 0 ]; then
    "$@"
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$timeout_sec" "$@"
    return $?
  fi
  "$@" &
  local cmd_pid=$!
  (
    sleep "$timeout_sec"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      kill -TERM "$cmd_pid" 2>/dev/null || true
      sleep 2
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) &
  local watchdog_pid=$!
  wait "$cmd_pid"
  local status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [ "$status" -eq 143 ] || [ "$status" -eq 137 ]; then
    return 124
  fi
  return "$status"
}

run_stage() {
  local name="$1"
  shift
  local start end elapsed status
  start="$(date +%s)"
  echo "[selfbuild] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfbuild] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[selfbuild] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  local start end elapsed status
  start="$(date +%s)"
  echo "[selfbuild] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfbuild] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[selfbuild] done: $name (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$name" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
}

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

SELFBUILD_START_SEC="$(date +%s)"
mkdir -p "$OUT_DIR"
rm -f "$STAGE1_WASM" "$STAGE2_WASM"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost WASI Selfbuild Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if ! is_non_negative_int "$STAGE_TIMEOUT_SEC"; then
  echo "selfbuild gate failed: VIBE_SELFHOST_SELFBUILD_STAGE_TIMEOUT_SEC must be integer seconds" >&2
  exit 1
fi
if [ "$STRICT_RECURSIVE" != "0" ] && [ "$STRICT_RECURSIVE" != "1" ]; then
  echo "selfbuild gate failed: VIBE_SELFHOST_SELFBUILD_STRICT_RECURSIVE must be 0 or 1" >&2
  exit 1
fi
if [ "$REQUIRE_TRUE_RECURSIVE" != "0" ] && [ "$REQUIRE_TRUE_RECURSIVE" != "1" ]; then
  echo "selfbuild gate failed: VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE must be 0 or 1" >&2
  exit 1
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "stage timeout" "$STAGE_TIMEOUT_SEC" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "strict recursive" "$STRICT_RECURSIVE" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "require true recursive" "$REQUIRE_TRUE_RECURSIVE" >> "$GITHUB_STEP_SUMMARY" || true
fi

if ! command -v moonrun >/dev/null 2>&1; then
  echo "selfbuild gate failed: moonrun not found" >&2
  exit 1
fi

# Build selfhost compiler wasm if missing/stale
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  run_stage "building selfhost compiler (wasm)" \
    moon build --target wasm src/cmd/vibe_compile_wasi
fi
if [ ! -f "$STAGE1_COMPILER_WASM" ]; then
  echo "selfbuild gate failed: stage1 compiler wasm not found: $STAGE1_COMPILER_WASM" >&2
  exit 1
fi

run_stage "stage0 (wasm compiler via moonrun) -> stage1 wasm compile" \
  moonrun "$STAGE1_COMPILER_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE1_WASM"

recursive_stage2_ok=0
RECURSIVE_STAGE2_LOG="$OUT_DIR/stage2_recursive_compile.log"
recursive_start="$(date +%s)"
recursive_runner_mode=0
cache_probe_runner_mode=0
CACHE_PROBE_COUNT1="na"
CACHE_PROBE_COUNT2="na"
FS_PARSE_CACHE_PROBE_COUNT1="na"
FS_PARSE_CACHE_PROBE_COUNT2="na"
GROUP_MERGE_CACHE_PROBE_COUNT1="na"
GROUP_MERGE_CACHE_PROBE_COUNT2="na"
MODULE_SOURCE_CACHE_PROBE_COUNT1="na"
MODULE_SOURCE_CACHE_PROBE_COUNT2="na"
CODEGEN_CACHE_PROBE_COUNT1="na"
CODEGEN_CACHE_PROBE_COUNT2="na"
CLI_CACHE_PROBE_COUNT1="na"
CLI_CACHE_PROBE_COUNT2="na"
recursive_stage_name="stage1 artifact (generated wasm) -> stage2 wasm compile"
node_runner_cmd=(node)
if command -v node >/dev/null 2>&1; then
  if node --experimental-wasm-exnref -e "" >/dev/null 2>&1; then
    node_runner_cmd+=(--experimental-wasm-exnref)
  fi
fi
if [ "$ENTRY_PATH" = "$DEFAULT_ENTRY_PATH" ] && \
  [ -f "$VIBE_HOST_RUNNER" ] && \
  command -v node >/dev/null 2>&1; then
  cache_probe_runner_mode=1
fi
if [ "$ENTRY_PATH" = "$DEFAULT_ENTRY_PATH" ] && \
  [ "$OUT_DIR" = "$DEFAULT_OUT_DIR" ] && \
  [ -f "$VIBE_HOST_RUNNER" ] && \
  command -v node >/dev/null 2>&1; then
  recursive_runner_mode=1
  recursive_stage_name="stage1 artifact (generated wasm) -> stage2 wasm compile (invoke selfbuild_compile_stage2)"
fi
if [ "$cache_probe_runner_mode" -eq 1 ]; then
  CACHE_PROBE_OUT="$OUT_DIR/stage1_cache_probe.out"
  run_stage_capture_stdout "run stage1 cache probe (--invoke selfbuild_probe_type_db_cache_counts)" \
    "$CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_type_db_cache_counts "$STAGE1_WASM"
  CACHE_PROBE_RAW="$(rg -v '^warning' "$CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 cache probe did not return packed counts: $CACHE_PROBE_RAW" >&2
    exit 1
  fi
  CACHE_PROBE_COUNT1="$((CACHE_PROBE_RAW / 1000))"
  CACHE_PROBE_COUNT2="$((CACHE_PROBE_RAW % 1000))"
  if [ "$CACHE_PROBE_COUNT1" -le 0 ]; then
    echo "selfbuild gate failed: stage1 cache probe first count must be positive, got $CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  if [ "$CACHE_PROBE_COUNT2" -ne "$CACHE_PROBE_COUNT1" ]; then
    echo "selfbuild gate failed: stage1 cache probe did not reuse warm typecheck state ($CACHE_PROBE_COUNT1 -> $CACHE_PROBE_COUNT2)" >&2
    exit 1
  fi
  echo "[selfbuild] cache probe counts: $CACHE_PROBE_COUNT1 -> $CACHE_PROBE_COUNT2"

  FS_PARSE_CACHE_PROBE_OUT="$OUT_DIR/stage1_fs_parse_cache_probe.out"
  run_stage_capture_stdout "run stage1 fs parse cache probe (--invoke selfbuild_probe_type_db_fs_parse_counts)" \
    "$FS_PARSE_CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_type_db_fs_parse_counts "$STAGE1_WASM"
  FS_PARSE_CACHE_PROBE_RAW="$(rg -v '^warning' "$FS_PARSE_CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$FS_PARSE_CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 fs parse cache probe did not return packed counts: $FS_PARSE_CACHE_PROBE_RAW" >&2
    exit 1
  fi
  FS_PARSE_CACHE_PROBE_COUNT1="$((FS_PARSE_CACHE_PROBE_RAW / 1000))"
  FS_PARSE_CACHE_PROBE_COUNT2="$((FS_PARSE_CACHE_PROBE_RAW % 1000))"
  if [ "$FS_PARSE_CACHE_PROBE_COUNT1" -lt 1 ]; then
    echo "selfbuild gate failed: stage1 fs parse cache probe first count must be positive, got $FS_PARSE_CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  echo "[selfbuild] fs parse cache probe counts: $FS_PARSE_CACHE_PROBE_COUNT1 -> $FS_PARSE_CACHE_PROBE_COUNT2"

  GROUP_MERGE_CACHE_PROBE_OUT="$OUT_DIR/stage1_group_merge_cache_probe.out"
  run_stage_capture_stdout "run stage1 grouped merge cache probe (--invoke selfbuild_probe_type_db_group_merge_counts)" \
    "$GROUP_MERGE_CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_type_db_group_merge_counts "$STAGE1_WASM"
  GROUP_MERGE_CACHE_PROBE_RAW="$(rg -v '^warning' "$GROUP_MERGE_CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$GROUP_MERGE_CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 grouped merge cache probe did not return packed counts: $GROUP_MERGE_CACHE_PROBE_RAW" >&2
    exit 1
  fi
  GROUP_MERGE_CACHE_PROBE_COUNT1="$((GROUP_MERGE_CACHE_PROBE_RAW / 1000))"
  GROUP_MERGE_CACHE_PROBE_COUNT2="$((GROUP_MERGE_CACHE_PROBE_RAW % 1000))"
  if [ "$GROUP_MERGE_CACHE_PROBE_COUNT1" -le 0 ]; then
    echo "selfbuild gate failed: stage1 grouped merge cache probe first count must be positive, got $GROUP_MERGE_CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  if [ "$GROUP_MERGE_CACHE_PROBE_COUNT2" -ne "$GROUP_MERGE_CACHE_PROBE_COUNT1" ]; then
    echo "selfbuild gate failed: stage1 grouped merge cache probe did not reuse warm grouped merge state ($GROUP_MERGE_CACHE_PROBE_COUNT1 -> $GROUP_MERGE_CACHE_PROBE_COUNT2)" >&2
    exit 1
  fi
  echo "[selfbuild] grouped merge cache probe counts: $GROUP_MERGE_CACHE_PROBE_COUNT1 -> $GROUP_MERGE_CACHE_PROBE_COUNT2"

  MODULE_SOURCE_CACHE_PROBE_OUT="$OUT_DIR/stage1_module_source_cache_probe.out"
  run_stage_capture_stdout "run stage1 module source cache probe (--invoke selfbuild_probe_type_db_module_source_counts)" \
    "$MODULE_SOURCE_CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_type_db_module_source_counts "$STAGE1_WASM"
  MODULE_SOURCE_CACHE_PROBE_RAW="$(rg -v '^warning' "$MODULE_SOURCE_CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$MODULE_SOURCE_CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 module source cache probe did not return packed counts: $MODULE_SOURCE_CACHE_PROBE_RAW" >&2
    exit 1
  fi
  MODULE_SOURCE_CACHE_PROBE_COUNT1="$((MODULE_SOURCE_CACHE_PROBE_RAW / 1000))"
  MODULE_SOURCE_CACHE_PROBE_COUNT2="$((MODULE_SOURCE_CACHE_PROBE_RAW % 1000))"
  if [ "$MODULE_SOURCE_CACHE_PROBE_COUNT1" -le 0 ]; then
    echo "selfbuild gate failed: stage1 module source cache probe first count must be positive, got $MODULE_SOURCE_CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  if [ "$MODULE_SOURCE_CACHE_PROBE_COUNT2" -ne "$MODULE_SOURCE_CACHE_PROBE_COUNT1" ]; then
    echo "selfbuild gate failed: stage1 module source cache probe did not reuse warm module source state ($MODULE_SOURCE_CACHE_PROBE_COUNT1 -> $MODULE_SOURCE_CACHE_PROBE_COUNT2)" >&2
    exit 1
  fi
  echo "[selfbuild] module source cache probe counts: $MODULE_SOURCE_CACHE_PROBE_COUNT1 -> $MODULE_SOURCE_CACHE_PROBE_COUNT2"

  CODEGEN_CACHE_PROBE_OUT="$OUT_DIR/stage1_codegen_cache_probe.out"
  run_stage_capture_stdout "run stage1 codegen cache probe (--invoke selfbuild_probe_type_db_codegen_counts)" \
    "$CODEGEN_CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_type_db_codegen_counts "$STAGE1_WASM"
  CODEGEN_CACHE_PROBE_RAW="$(rg -v '^warning' "$CODEGEN_CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$CODEGEN_CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 codegen cache probe did not return packed counts: $CODEGEN_CACHE_PROBE_RAW" >&2
    exit 1
  fi
  CODEGEN_CACHE_PROBE_COUNT1="$((CODEGEN_CACHE_PROBE_RAW / 1000))"
  CODEGEN_CACHE_PROBE_COUNT2="$((CODEGEN_CACHE_PROBE_RAW % 1000))"
  if [ "$CODEGEN_CACHE_PROBE_COUNT1" -le 0 ]; then
    echo "selfbuild gate failed: stage1 codegen cache probe first count must be positive, got $CODEGEN_CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  if [ "$CODEGEN_CACHE_PROBE_COUNT2" -ne "$CODEGEN_CACHE_PROBE_COUNT1" ]; then
    echo "selfbuild gate failed: stage1 codegen cache probe did not reuse warm artifact state ($CODEGEN_CACHE_PROBE_COUNT1 -> $CODEGEN_CACHE_PROBE_COUNT2)" >&2
    exit 1
  fi
  echo "[selfbuild] codegen cache probe counts: $CODEGEN_CACHE_PROBE_COUNT1 -> $CODEGEN_CACHE_PROBE_COUNT2"

  CLI_CACHE_PROBE_OUT="$OUT_DIR/stage1_cli_cache_probe.out"
  run_stage_capture_stdout "run stage1 cli cache probe (--invoke selfbuild_probe_cli_file_cache_counts)" \
    "$CLI_CACHE_PROBE_OUT" \
    "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_probe_cli_file_cache_counts "$STAGE1_WASM"
  CLI_CACHE_PROBE_RAW="$(rg -v '^warning' "$CLI_CACHE_PROBE_OUT" | tail -n 1)"
  if ! is_non_negative_int "$CLI_CACHE_PROBE_RAW"; then
    echo "selfbuild gate failed: stage1 cli cache probe did not return packed counts: $CLI_CACHE_PROBE_RAW" >&2
    exit 1
  fi
  CLI_CACHE_PROBE_COUNT1="$((CLI_CACHE_PROBE_RAW / 1000))"
  CLI_CACHE_PROBE_COUNT2="$((CLI_CACHE_PROBE_RAW % 1000))"
  if [ "$CLI_CACHE_PROBE_COUNT1" -le 0 ]; then
    echo "selfbuild gate failed: stage1 cli cache probe first count must be positive, got $CLI_CACHE_PROBE_COUNT1" >&2
    exit 1
  fi
  if [ "$CLI_CACHE_PROBE_COUNT2" -ne "$CLI_CACHE_PROBE_COUNT1" ]; then
    echo "selfbuild gate failed: stage1 cli cache probe did not reuse warm file-backed typecheck state ($CLI_CACHE_PROBE_COUNT1 -> $CLI_CACHE_PROBE_COUNT2)" >&2
    exit 1
  fi
  echo "[selfbuild] cli cache probe counts: $CLI_CACHE_PROBE_COUNT1 -> $CLI_CACHE_PROBE_COUNT2"
fi
echo "[selfbuild] $recursive_stage_name"
set +e
if [ "$recursive_runner_mode" -eq 1 ]; then
  (
    cd "$PROJECT_ROOT"
    run_with_timeout "$STAGE_TIMEOUT_SEC" \
      "${node_runner_cmd[@]}" "$VIBE_HOST_RUNNER" --invoke selfbuild_compile_stage2 "$STAGE1_WASM"
  ) >"$RECURSIVE_STAGE2_LOG" 2>&1
  recursive_status=$?
else
  run_with_timeout "$STAGE_TIMEOUT_SEC" moonrun "$STAGE1_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE2_WASM" >"$RECURSIVE_STAGE2_LOG" 2>&1
  recursive_status=$?
fi
set -e
if [ "$recursive_status" -eq 124 ]; then
  echo "[selfbuild] timeout: $recursive_stage_name (${STAGE_TIMEOUT_SEC}s)" >&2
fi
if [ "$recursive_status" -eq 0 ] && [ -s "$STAGE2_WASM" ]; then
  recursive_end="$(date +%s)"
  recursive_elapsed="$((recursive_end - recursive_start))"
  echo "[selfbuild] done: $recursive_stage_name (${recursive_elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$recursive_stage_name" "$recursive_elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  recursive_stage2_ok=1
else
  if [ "$STRICT_RECURSIVE" = "1" ]; then
    echo "[selfbuild] strict recursive mode: generated artifact could not compile stage2; using seed compiler fallback" >&2
  else
    echo "[selfbuild] warning: stage1 artifact is not usable as compiler; fallback to seed compiler" >&2
  fi
  if [ -s "$RECURSIVE_STAGE2_LOG" ]; then
    echo "[selfbuild] recursive compile log (tail):" >&2
    tail -n 20 "$RECURSIVE_STAGE2_LOG" >&2 || true
  fi
  if [ "$REQUIRE_TRUE_RECURSIVE" = "1" ]; then
    echo "selfbuild gate failed: generated stage1 artifact could not compile stage2 and fallback is disabled (set VIBE_SELFHOST_SELFBUILD_REQUIRE_TRUE_RECURSIVE=0 to allow fallback)" >&2
    exit 1
  fi
  run_stage "fallback seed compiler -> stage2 wasm compile" \
    moonrun "$STAGE1_COMPILER_WASM" --wasm-mvp "$ENTRY_PATH" -o "$STAGE2_WASM"
fi

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate stage1 wasm" wasm-tools validate --features all "$STAGE1_WASM"
  run_stage "validate stage2 wasm" wasm-tools validate --features all "$STAGE2_WASM"
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

HASH_STAGE1="$(shasum -a 256 "$STAGE1_WASM" | awk '{print $1}')"
HASH_STAGE2="$(shasum -a 256 "$STAGE2_WASM" | awk '{print $1}')"
if [ "$HASH_STAGE1" != "$HASH_STAGE2" ]; then
  if [ "$recursive_stage2_ok" -eq 1 ]; then
    # Meta-circular compilation succeeded: stage1 (seed codegen) != stage2 (selfhost codegen)
    # is expected — different codegens produce different binaries.
    echo "[selfbuild] stage1/stage2 hash differs (expected: different codegens)"
    echo "  stage1: $HASH_STAGE1"
    echo "  stage2: $HASH_STAGE2"
  else
    # Fallback mode: both compiled by seed compiler, hashes MUST match.
    echo "selfbuild gate failed: stage1/stage2 wasm hash mismatch" >&2
    echo "  stage1: $HASH_STAGE1" >&2
    echo "  stage2: $HASH_STAGE2" >&2
    exit 1
  fi
fi

run_stage_capture_stdout "run stage1 wasm via wasmtime (--invoke run)" \
  "$OUT_DIR/stage1_run.out" \
  env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE1_WASM"

run_stage_capture_stdout "run stage2 wasm via wasmtime (--invoke run)" \
  "$OUT_DIR/stage2_run.out" \
  env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
  "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke run "$STAGE2_WASM"

RUN_STAGE1="$(rg -v '^warning' "$OUT_DIR/stage1_run.out" | tail -n 1)"
RUN_STAGE2="$(rg -v '^warning' "$OUT_DIR/stage2_run.out" | tail -n 1)"
if ! [[ "$RUN_STAGE1" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage1 run did not return numeric value: $RUN_STAGE1" >&2
  exit 1
fi
if ! [[ "$RUN_STAGE2" =~ ^-?[0-9]+$ ]]; then
  echo "selfbuild gate failed: stage2 run did not return numeric value: $RUN_STAGE2" >&2
  exit 1
fi

if [ "$RUN_STAGE1" != "0" ]; then
  echo "selfbuild gate failed: expected stage1 run return 0, got $RUN_STAGE1" >&2
  exit 1
fi
if [ "$RUN_STAGE2" != "0" ]; then
  echo "selfbuild gate failed: expected stage2 run return 0, got $RUN_STAGE2" >&2
  exit 1
fi

recursive_mode="strict-recursive"
if [ "$recursive_stage2_ok" -eq 0 ]; then
  recursive_mode="seed-fallback"
fi
SELFBUILD_END_SEC="$(date +%s)"
SELFBUILD_TOTAL_SEC="$((SELFBUILD_END_SEC - SELFBUILD_START_SEC))"
echo "[selfbuild] total elapsed: ${SELFBUILD_TOTAL_SEC}s"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %ss\n" "total elapsed" "$SELFBUILD_TOTAL_SEC" >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ "$SELFBUILD_MAX_TOTAL_SEC" -gt 0 ] 2>/dev/null; then
  if [ "$SELFBUILD_TOTAL_SEC" -gt "$SELFBUILD_MAX_TOTAL_SEC" ]; then
    echo "selfbuild KPI failed: total ${SELFBUILD_TOTAL_SEC}s > max ${SELFBUILD_MAX_TOTAL_SEC}s" >&2
    exit 1
  fi
  echo "[selfbuild] KPI passed: total ${SELFBUILD_TOTAL_SEC}s <= max ${SELFBUILD_MAX_TOTAL_SEC}s"
fi

SIZE_STAGE1="$(wc -c < "$STAGE1_WASM" | tr -d ' ')"
SIZE_STAGE2="$(wc -c < "$STAGE2_WASM" | tr -d ' ')"
echo "selfbuild gate passed: stage1_hash=$HASH_STAGE1 stage2_hash=$HASH_STAGE2 stage1_size=$SIZE_STAGE1 stage2_size=$SIZE_STAGE2 stage1_run=$RUN_STAGE1 stage2_run=$RUN_STAGE2 cache_prepare_count1=$CACHE_PROBE_COUNT1 cache_prepare_count2=$CACHE_PROBE_COUNT2 group_merge_cache_count1=$GROUP_MERGE_CACHE_PROBE_COUNT1 group_merge_cache_count2=$GROUP_MERGE_CACHE_PROBE_COUNT2 module_source_cache_count1=$MODULE_SOURCE_CACHE_PROBE_COUNT1 module_source_cache_count2=$MODULE_SOURCE_CACHE_PROBE_COUNT2 codegen_cache_count1=$CODEGEN_CACHE_PROBE_COUNT1 codegen_cache_count2=$CODEGEN_CACHE_PROBE_COUNT2 cli_cache_prepare_count1=$CLI_CACHE_PROBE_COUNT1 cli_cache_prepare_count2=$CLI_CACHE_PROBE_COUNT2 mode=$recursive_mode recursive=$recursive_stage2_ok total=${SELFBUILD_TOTAL_SEC}s"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VIBE_BIN="${VIBE_BIN:-$PROJECT_ROOT/target/native/release/build/cmd/vibe/vibe.exe}"
OUT_DIR="${OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_bootstrap}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
KPI_BASELINE_SEC="${VIBE_SELFHOST_BOOTSTRAP_BASELINE_SEC:-}"
KPI_REDUCTION_PCT="${VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT:-30}"
PIPELINE_OPT_LEVEL="${VIBE_SELFHOST_PIPELINE_OPT_LEVEL:-}"
SELFHOST_TEST_JOBS="${VIBE_SELFHOST_BOOTSTRAP_TEST_JOBS:-}"
SELFHOST_BATCH_CHUNK_SIZE="${VIBE_SELFHOST_BOOTSTRAP_BATCH_CHUNK_SIZE:-1}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_BOOTSTRAP_STAGE_TIMEOUT_SEC:-1800}"
BATCH_WEIGHT_CACHE_PATH="${VIBE_SELFHOST_BOOTSTRAP_BATCH_WEIGHT_CACHE:-$OUT_DIR/selfhost_test_batch_weights.json}"
BATCH_WEIGHT_SEED_PATH="${VIBE_SELFHOST_BOOTSTRAP_BATCH_WEIGHT_SEED:-$PROJECT_ROOT/scripts/selfhost_test_batch_weights.seed.json}"
# Cutover: use selfhost compiler (moonrun) instead of host CLI for wasm compilation.
# Set VIBE_SELFHOST_CUTOVER=0 to fall back to host CLI (emergency rollback).
SELFHOST_CUTOVER="${VIBE_SELFHOST_CUTOVER:-1}"
SELFHOST_COMPILER_WASM="${SELFHOST_COMPILER_WASM:-$PROJECT_ROOT/_build/wasm/debug/build/cmd/vibe_compile_wasi/vibe_compile_wasi.wasm}"

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
  echo "[bootstrap] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[bootstrap] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $name (${elapsed}s)"
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
  echo "[bootstrap] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[bootstrap] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $name (${elapsed}s)"
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

is_positive_int() {
  if ! is_non_negative_int "$1"; then
    return 1
  fi
  [ "$1" -gt 0 ]
}

detect_default_test_jobs() {
  local cpus
  cpus=""
  if command -v nproc >/dev/null 2>&1; then
    cpus="$(nproc || true)"
  elif command -v sysctl >/dev/null 2>&1; then
    cpus="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if ! is_positive_int "${cpus:-}"; then
    cpus=4
  fi
  if [ "$cpus" -gt 16 ]; then
    cpus=16
  fi
  echo "$cpus"
}

run_wasm_and_expect_zero() {
  local label="$1"
  local wasm_path="$2"
  local out_path="$3"
  local start end elapsed run_value status
  start="$(date +%s)"
  echo "[bootstrap] $label"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" env VIBE_WASMTIME_WASM_FLAGS="unknown-imports-default=y exceptions=y" \
    "$PROJECT_ROOT/scripts/wasmtime_run.sh" --invoke _start "$wasm_path" >"$out_path"
  status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[bootstrap] timeout: $label (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
  end="$(date +%s)"
  elapsed="$((end - start))"
  echo "[bootstrap] done: $label (${elapsed}s)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- %s: %ss\n" "$label" "$elapsed" >> "$GITHUB_STEP_SUMMARY" || true
  fi
  run_value="$(rg -v '^warning' "$out_path" | tail -n 1)"
  if ! [[ "$run_value" =~ ^-?[0-9]+$ ]]; then
    echo "bootstrap gate failed: $label did not return numeric value: $run_value" >&2
    exit 1
  fi
  if [ "$run_value" != "0" ]; then
    echo "bootstrap gate failed: expected $label return 0, got $run_value" >&2
    exit 1
  fi
}

hash_wasm_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_stage_pair_hash() {
  local output_prefix="$1"
  local source_path="$2"
  local mode_label="$3"
  shift 3

  local pair_stage1="$OUT_DIR/${output_prefix}_stage1.wasm"
  local pair_stage2="$OUT_DIR/${output_prefix}_stage2.wasm"
  local pair_hash1 pair_hash2

  run_stage "stage1 compile (${mode_label}) for $source_path" \
    "${COMPILE_CMD_ARGS[@]}" "$@" "$source_path" -o "$pair_stage1"
  run_stage "stage2 compile (${mode_label}) for $source_path" \
    "${COMPILE_CMD_ARGS[@]}" "$@" "$source_path" -o "$pair_stage2"

  if command -v wasm-tools >/dev/null 2>&1; then
    run_stage "validate ${output_prefix} stage1 wasm" wasm-tools validate --features all "$pair_stage1"
    run_stage "validate ${output_prefix} stage2 wasm" wasm-tools validate --features all "$pair_stage2"
  fi

  pair_hash1="$(hash_wasm_file "$pair_stage1")"
  pair_hash2="$(hash_wasm_file "$pair_stage2")"
  if [ "$pair_hash1" != "$pair_hash2" ]; then
    echo "bootstrap gate failed: deterministic hash mismatch (${mode_label})" >&2
    echo "  source: $source_path" >&2
    echo "  stage1: $pair_hash1" >&2
    echo "  stage2: $pair_hash2" >&2
    exit 1
  fi

  echo "[bootstrap] deterministic hash ok: mode=${mode_label} source=${source_path#$PROJECT_ROOT/} hash=$pair_hash1"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf -- "- deterministic hash: mode=%s source=%s hash=%s\n" \
      "$mode_label" "${source_path#$PROJECT_ROOT/}" "$pair_hash1" >> "$GITHUB_STEP_SUMMARY" || true
  fi

  STAGE_PAIR_LAST_STAGE1="$pair_stage1"
  STAGE_PAIR_LAST_STAGE2="$pair_stage2"
  STAGE_PAIR_LAST_HASH="$pair_hash1"
  DETERMINISTIC_CASES_CHECKED=$((DETERMINISTIC_CASES_CHECKED + 1))
}

bootstrap_total_start="$(date +%s)"
DETERMINISTIC_CASES_CHECKED=0

needs_cli_rebuild=0
if [ ! -x "$VIBE_BIN" ]; then
  needs_cli_rebuild=1
elif [ "$PROJECT_ROOT/moon.mod.json" -nt "$VIBE_BIN" ]; then
  needs_cli_rebuild=1
elif find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$VIBE_BIN" -print -quit | grep -q .; then
  needs_cli_rebuild=1
fi

if [ "$needs_cli_rebuild" -eq 1 ]; then
  run_stage "building vibe CLI (native release)" \
    moon build --target native --release src/cmd/vibe --warn-list '-29'
fi

# Build selfhost compiler wasm if cutover is enabled and binary is missing/stale
if [ "$SELFHOST_CUTOVER" = "1" ]; then
  needs_selfhost_rebuild=0
  if [ ! -f "$SELFHOST_COMPILER_WASM" ]; then
    needs_selfhost_rebuild=1
  elif [ "$PROJECT_ROOT/moon.mod.json" -nt "$SELFHOST_COMPILER_WASM" ]; then
    needs_selfhost_rebuild=1
  elif find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$SELFHOST_COMPILER_WASM" -print -quit 2>/dev/null | grep -q .; then
    needs_selfhost_rebuild=1
  fi
  if [ "$needs_selfhost_rebuild" -eq 1 ]; then
    run_stage "building selfhost compiler (wasm)" \
      moon build --target wasm src/cmd/vibe_compile_wasi
  fi
  if ! command -v moonrun >/dev/null 2>&1; then
    echo "bootstrap gate failed: moonrun not found (required for VIBE_SELFHOST_CUTOVER=1)" >&2
    exit 1
  fi
  echo "[bootstrap] cutover: using selfhost compiler (moonrun)"
  COMPILE_CMD_ARGS=(moonrun "$SELFHOST_COMPILER_WASM")
else
  echo "[bootstrap] cutover: using host CLI"
  COMPILE_CMD_ARGS=("$VIBE_BIN" compile)
fi

mkdir -p "$OUT_DIR"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost Bootstrap Gate Timings"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ -z "$SELFHOST_TEST_JOBS" ]; then
  SELFHOST_TEST_JOBS="$(detect_default_test_jobs)"
fi
if ! is_positive_int "$SELFHOST_TEST_JOBS"; then
  echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_TEST_JOBS must be positive integer" >&2
  exit 1
fi
if ! is_positive_int "$SELFHOST_BATCH_CHUNK_SIZE"; then
  echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_BATCH_CHUNK_SIZE must be positive integer" >&2
  exit 1
fi
if ! is_non_negative_int "$STAGE_TIMEOUT_SEC"; then
  echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_STAGE_TIMEOUT_SEC must be integer seconds" >&2
  exit 1
fi
if [ "$SELFHOST_TEST_JOBS" -gt 16 ]; then
  SELFHOST_TEST_JOBS=16
fi
echo "[bootstrap] selfhost test jobs: $SELFHOST_TEST_JOBS"
echo "[bootstrap] selfhost batch chunk size: $SELFHOST_BATCH_CHUNK_SIZE"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf -- "- %s: %s\n" "selfhost test jobs" "$SELFHOST_TEST_JOBS" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "selfhost batch chunk size" "$SELFHOST_BATCH_CHUNK_SIZE" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %ss\n" "stage timeout" "$STAGE_TIMEOUT_SEC" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "cutover" "$( [ "$SELFHOST_CUTOVER" = "1" ] && echo "selfhost (moonrun)" || echo "host CLI" )" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "batch weight cache" "$BATCH_WEIGHT_CACHE_PATH" >> "$GITHUB_STEP_SUMMARY" || true
  printf -- "- %s: %s\n" "batch weight seed" "$BATCH_WEIGHT_SEED_PATH" >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ ! -f "$BATCH_WEIGHT_CACHE_PATH" ] && [ -f "$BATCH_WEIGHT_SEED_PATH" ]; then
  cp "$BATCH_WEIGHT_SEED_PATH" "$BATCH_WEIGHT_CACHE_PATH"
fi

SELFHOST_COMPILED_TEST_FILES=()
for test_path in "$PROJECT_ROOT"/vibe/compiler/*_test.vibe; do
  test_name="$(basename "$test_path")"
  case "$test_name" in
    selfhost_s5_test.vibe|selfhost_s5_*_test.vibe|codegen_parser_test.vibe|compiler_cache_test.vibe|cli_cache_test.vibe|cli_adapter_cache_test.vibe|codegen_enum_import_test.vibe|cache_probe_*_bench_test.vibe|compiler_fs_test.vibe|module_loader_check_module_test.vibe|fixture_real_selfhost_test.vibe|checker_error_format_test.vibe|compiler_cache_advanced_test.vibe|file_compile_mode_test.vibe|codegen_regression_test.vibe|module_loader_collect_sources_test.vibe|persistent_cache_test.vibe|type_db_cross_module_test.vibe|compiler_cache_prepare_test.vibe|codegen_struct_test.vibe|fixture_test.vibe|coverage_selfhost_suite_lib_test.vibe|loader_persistent_cache_test.vibe|wasm_emit_test.vibe|codegen_test.vibe|module_loader_test.vibe|fixture_roundtrip_test.vibe)
      ;;
    *)
      SELFHOST_COMPILED_TEST_FILES+=("$test_path")
      ;;
  esac
done

run_compiled_selfhost_test_shard() {
  local shard_label="$1"
  shift
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  if command -v stdbuf >/dev/null 2>&1; then
    run_stage "compiled selfhost test suite shard ${shard_label}" \
      env VIBE_TEST_BACKEND=compiled VIBE_TEST_JOBS="$SELFHOST_TEST_JOBS" \
      VIBE_TEST_BATCH_CHUNK_SIZE="$SELFHOST_BATCH_CHUNK_SIZE" \
      VIBE_TEST_BATCH_WEIGHT_CACHE="$BATCH_WEIGHT_CACHE_PATH" \
      stdbuf -oL -eL \
      "$VIBE_BIN" test --jobs "$SELFHOST_TEST_JOBS" "$@"
  else
    run_stage "compiled selfhost test suite shard ${shard_label}" \
      env VIBE_TEST_BACKEND=compiled VIBE_TEST_JOBS="$SELFHOST_TEST_JOBS" \
      VIBE_TEST_BATCH_CHUNK_SIZE="$SELFHOST_BATCH_CHUNK_SIZE" \
      VIBE_TEST_BATCH_WEIGHT_CACHE="$BATCH_WEIGHT_CACHE_PATH" \
      "$VIBE_BIN" test --jobs "$SELFHOST_TEST_JOBS" "$@"
  fi
}

SELFHOST_COMPILED_TEST_FILES_SHARD_0=()
SELFHOST_COMPILED_TEST_FILES_SHARD_1=()
SELFHOST_COMPILED_TEST_FILES_SHARD_2=()
SELFHOST_COMPILED_TEST_FILES_SHARD_3=()
shard_index=0
for test_path in "${SELFHOST_COMPILED_TEST_FILES[@]}"; do
  case "$shard_index" in
    0)
      SELFHOST_COMPILED_TEST_FILES_SHARD_0+=("$test_path")
      ;;
    1)
      SELFHOST_COMPILED_TEST_FILES_SHARD_1+=("$test_path")
      ;;
    2)
      SELFHOST_COMPILED_TEST_FILES_SHARD_2+=("$test_path")
      ;;
    *)
      SELFHOST_COMPILED_TEST_FILES_SHARD_3+=("$test_path")
      ;;
  esac
  shard_index=$(((shard_index + 1) % 4))
done

run_compiled_selfhost_test_shard "1/4" "${SELFHOST_COMPILED_TEST_FILES_SHARD_0[@]}"
run_compiled_selfhost_test_shard "2/4" "${SELFHOST_COMPILED_TEST_FILES_SHARD_1[@]}"
run_compiled_selfhost_test_shard "3/4" "${SELFHOST_COMPILED_TEST_FILES_SHARD_2[@]}"
run_compiled_selfhost_test_shard "4/4" "${SELFHOST_COMPILED_TEST_FILES_SHARD_3[@]}"

run_stage "compiled selfhost cli cache test" \
  env VIBE_TEST_BACKEND=compiled \
  "$VIBE_BIN" test "$PROJECT_ROOT/vibe/compiler/cli_cache_test.vibe"

run_stage "compiled selfhost cli adapter cache test" \
  env VIBE_TEST_BACKEND=compiled \
  "$VIBE_BIN" test "$PROJECT_ROOT/vibe/compiler/cli_adapter_cache_test.vibe"

run_stage "compiled selfhost codegen enum import test" \
  env VIBE_TEST_BACKEND=compiled \
  "$VIBE_BIN" test "$PROJECT_ROOT/vibe/compiler/codegen_enum_import_test.vibe"

run_stage "compiled selfhost compiler cache test" \
  env VIBE_TEST_BACKEND=compiled \
  "$VIBE_BIN" test "$PROJECT_ROOT/vibe/compiler/compiler_cache_test.vibe"

echo "[bootstrap] selfhost __to_string source path check"
if rg -n "double_to_string_compiler" \
  "$PROJECT_ROOT/vibe/compiler/values.vibe" \
  "$PROJECT_ROOT/vibe/compiler/token.vibe" \
  "$PROJECT_ROOT/vibe/compiler/printer.vibe" >/dev/null; then
  echo "bootstrap gate failed: selfhost compiler still depends on double_to_string_compiler" >&2
  exit 1
fi

TOSTRING_PROBE="$OUT_DIR/selfhost_tostring_probe.vibe"
cat >"$TOSTRING_PROBE" <<'EOF'
test "__to_string number parity" {
  assert(String::equals(__to_string(1.5), "1.5"))
  assert(String::equals(__to_string(2.0), "2"))
  assert(String::equals(__to_string(1.5f), "1.5"))
}
EOF
run_stage "compiled __to_string(Double/Float) probe" \
  env VIBE_TEST_BACKEND=compiled "$VIBE_BIN" test "$TOSTRING_PROBE"

run_stage "selfhost probe smoke (vibe integration test index 44)" \
  moon test -p tests -f vibe_integration_test.mbt --target js --warn-list '-29' --index 44

BASICS_FIXTURE="$PROJECT_ROOT/examples/basics.vibe"
BASE64_FIXTURE="$PROJECT_ROOT/bench/compiler_size/cases/base64.vibe"
if [ ! -f "$BASICS_FIXTURE" ]; then
  echo "bootstrap gate failed: fixture not found: $BASICS_FIXTURE" >&2
  exit 1
fi
if [ ! -f "$BASE64_FIXTURE" ]; then
  echo "bootstrap gate failed: fixture not found: $BASE64_FIXTURE" >&2
  exit 1
fi

verify_stage_pair_hash "index_mvp" "$ENTRY_PATH" "--wasm" --wasm
STAGE1_WASM="$STAGE_PAIR_LAST_STAGE1"
STAGE2_WASM="$STAGE_PAIR_LAST_STAGE2"
HASH_STAGE1="$STAGE_PAIR_LAST_HASH"

verify_stage_pair_hash "index_no_dce" "$ENTRY_PATH" "--wasm --no-dce" --wasm --no-dce
verify_stage_pair_hash "index_debug_errors" "$ENTRY_PATH" "--wasm --debug-errors" --wasm --debug-errors
verify_stage_pair_hash "basics_mvp" "$BASICS_FIXTURE" "--wasm" --wasm
verify_stage_pair_hash "base64_mvp" "$BASE64_FIXTURE" "--wasm" --wasm

PIPELINE_CHECK="$OUT_DIR/index_pipeline_check.log"
PIPELINE_RAW_WASM="$OUT_DIR/index_pipeline_raw.wasm"
PIPELINE_OPT_WASM="$OUT_DIR/index_pipeline_opt.wasm"
run_stage_capture_stdout "pipeline parse+type check for $ENTRY_PATH" \
  "$PIPELINE_CHECK" \
  "$VIBE_BIN" check "$ENTRY_PATH"
run_stage "pipeline codegen (--wasm --no-dce) for $ENTRY_PATH" \
  "${COMPILE_CMD_ARGS[@]}" --wasm --no-dce "$ENTRY_PATH" -o "$PIPELINE_RAW_WASM"
if [ -n "$PIPELINE_OPT_LEVEL" ]; then
  run_stage "pipeline optimize/codegen (-O$PIPELINE_OPT_LEVEL) for $ENTRY_PATH" \
    "${COMPILE_CMD_ARGS[@]}" --wasm "-O$PIPELINE_OPT_LEVEL" "$ENTRY_PATH" -o "$PIPELINE_OPT_WASM"
else
  echo "[bootstrap] pipeline optimize/codegen: skipped (set VIBE_SELFHOST_PIPELINE_OPT_LEVEL)"
fi

if command -v wasm-tools >/dev/null 2>&1; then
  run_stage "validate pipeline raw wasm" wasm-tools validate --features all "$PIPELINE_RAW_WASM"
  if [ -n "$PIPELINE_OPT_LEVEL" ]; then
    run_stage "validate pipeline opt wasm" wasm-tools validate --features all "$PIPELINE_OPT_WASM"
  fi
else
  echo "warning: wasm-tools not found, skipping validate" >&2
fi

run_wasm_and_expect_zero \
  "run stage1 wasm via wasmtime (--invoke _start)" \
  "$STAGE1_WASM" \
  "$OUT_DIR/stage1_run.out"
run_wasm_and_expect_zero \
  "run stage2 wasm via wasmtime (--invoke _start)" \
  "$STAGE2_WASM" \
  "$OUT_DIR/stage2_run.out"

bootstrap_total_end="$(date +%s)"
bootstrap_total_elapsed="$((bootstrap_total_end - bootstrap_total_start))"
echo "[bootstrap] total elapsed: ${bootstrap_total_elapsed}s"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo
    echo "- deterministic cases checked: ${DETERMINISTIC_CASES_CHECKED}"
    echo "- total: ${bootstrap_total_elapsed}s"
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

if [ -n "$KPI_BASELINE_SEC" ]; then
  if ! is_non_negative_int "$KPI_BASELINE_SEC"; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_BASELINE_SEC must be integer seconds" >&2
    exit 1
  fi
  if ! is_non_negative_int "$KPI_REDUCTION_PCT"; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT must be integer percent" >&2
    exit 1
  fi
  if [ "$KPI_REDUCTION_PCT" -ge 100 ]; then
    echo "bootstrap gate failed: VIBE_SELFHOST_BOOTSTRAP_REDUCTION_PCT must be < 100" >&2
    exit 1
  fi
  target_sec=$((KPI_BASELINE_SEC * (100 - KPI_REDUCTION_PCT) / 100))
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "- kpi baseline: ${KPI_BASELINE_SEC}s"
      echo "- kpi target (${KPI_REDUCTION_PCT}%): <= ${target_sec}s"
      echo "- kpi actual: ${bootstrap_total_elapsed}s"
    } >> "$GITHUB_STEP_SUMMARY" || true
  fi
  if [ "$bootstrap_total_elapsed" -gt "$target_sec" ]; then
    echo "bootstrap gate failed: KPI target missed (baseline=${KPI_BASELINE_SEC}s target<=${target_sec}s actual=${bootstrap_total_elapsed}s)" >&2
    exit 1
  fi
fi

echo "bootstrap gate passed: hash=$HASH_STAGE1 deterministic_cases=${DETERMINISTIC_CASES_CHECKED} total=${bootstrap_total_elapsed}s"

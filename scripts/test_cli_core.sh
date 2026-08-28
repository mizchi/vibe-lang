#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_cli_core"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/lib/@vibe/cli/main.vibex}"
STAGE_TIMEOUT_SEC="${VIBE_CLI_CORE_STAGE_TIMEOUT_SEC:-300}"
BUILD_PRE_GROW_PAGES="${VIBE_CLI_CORE_BUILD_PRE_GROW_PAGES:-${VIBE_WASM_PRE_GROW_PAGES:-}}"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
INPUT_SOURCE="$OUT_DIR/core_env_input.vibe"
OUTPUT_WASM="$OUT_DIR/core_env_output.wasm"
OUTPUT_RUN_LOG="$OUT_DIR/core_output_run.log"
COMMAND_INPUT_SOURCE="$OUT_DIR/core_command_input.vibe"
COMMAND_OUTPUT_WASM="$OUT_DIR/core_command_output.wasm"
COMMAND_OUTPUT_RUN_LOG="$OUT_DIR/core_command_output_run.log"
COMMAND_PROFILE_TSV="$OUT_DIR/core_command_profile.tsv"
COMMAND_CALLSTACK_TSV="$OUT_DIR/core_command_callstack.tsv"
COMPILE_COMMAND_INPUT_SOURCE="$OUT_DIR/core_compile_command_input.vibe"
COMPILE_COMMAND_OUTPUT_WASM="$OUT_DIR/core_compile_command_output.wasm"
COMPILE_COMMAND_OUTPUT_RUN_LOG="$OUT_DIR/core_compile_command_output_run.log"
BUILD_COMMAND_INPUT_SOURCE="$OUT_DIR/core_build_command_input.vibe"
BUILD_COMMAND_OUTPUT_WASM="$OUT_DIR/core_build_command_output.wasm"
BUILD_COMMAND_OUTPUT_RUN_LOG="$OUT_DIR/core_build_command_output_run.log"
CHECK_COMMAND_INPUT_SOURCE="$OUT_DIR/core_check_command_input.vibe"
CHECK_COMMAND_PROFILE_TSV="$OUT_DIR/core_check_command_profile.tsv"
CHECK_COMMAND_CALLSTACK_TSV="$OUT_DIR/core_check_command_callstack.tsv"
DEBUG_LIB_SOURCE="$OUT_DIR/core_debug_lib.vibe"
DEBUG_MAIN_SOURCE="$OUT_DIR/core_debug_main.vibe"
DEBUG_OUTPUT_WASM="$OUT_DIR/core_debug_output.wasm"
DEBUG_OUTPUT_RUN_LOG="$OUT_DIR/core_debug_output_run.log"
DEBUG_OUTPUT_DIR="$OUT_DIR/core_debug_output.debug"
DEBUG_LIB_WASM="$DEBUG_OUTPUT_DIR/core_debug_lib.wasm"
DEBUG_STRING_LIB_SOURCE="$OUT_DIR/core_debug_string_lib.vibe"
DEBUG_STRING_MAIN_SOURCE="$OUT_DIR/core_debug_string_main.vibe"
DEBUG_STRING_OUTPUT_WASM="$OUT_DIR/core_debug_string_output.wasm"
DEBUG_STRING_OUTPUT_RUN_LOG="$OUT_DIR/core_debug_string_output_run.log"
DEBUG_STRING_OUTPUT_DIR="$OUT_DIR/core_debug_string_output.debug"
DEBUG_STRING_LIB_WASM="$DEBUG_STRING_OUTPUT_DIR/core_debug_string_lib.wasm"
ENTRY_NAME="answer"
HOST_MODE="${VIBE_CLI_CORE_HOST_MODE:-debug}"
WASMTIME_RUN="$PROJECT_ROOT/scripts/wasmtime_run.sh"
WASMTIME_WASM_FLAGS="${VIBE_WASMTIME_WASM_FLAGS:-exceptions=y}"

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
  echo "[selfhost-cli-core] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli-core] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

run_wasm_validate() {
  local name="$1"
  local wasm="$2"
  if command -v wasm-tools >/dev/null 2>&1; then
    run_stage "$name" wasm-tools validate "$wasm"
  else
    echo "[selfhost-cli-core] skip: $name (wasm-tools not installed)"
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  echo "[selfhost-cli-core] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli-core] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

mkdir -p "$OUT_DIR"
rm -f "$OUTPUT_WASM" "$OUTPUT_RUN_LOG" \
  "$COMMAND_INPUT_SOURCE" "$COMMAND_OUTPUT_WASM" "$COMMAND_OUTPUT_RUN_LOG" \
  "$COMMAND_PROFILE_TSV" "$COMMAND_CALLSTACK_TSV" \
  "$COMPILE_COMMAND_INPUT_SOURCE" "$COMPILE_COMMAND_OUTPUT_WASM" \
  "$COMPILE_COMMAND_OUTPUT_RUN_LOG" "$BUILD_COMMAND_INPUT_SOURCE" \
  "$BUILD_COMMAND_OUTPUT_WASM" "$BUILD_COMMAND_OUTPUT_RUN_LOG" \
  "$CHECK_COMMAND_INPUT_SOURCE" "$CHECK_COMMAND_PROFILE_TSV" "$CHECK_COMMAND_CALLSTACK_TSV" \
  "$DEBUG_LIB_SOURCE" "$DEBUG_MAIN_SOURCE" "$DEBUG_OUTPUT_WASM" "$DEBUG_OUTPUT_RUN_LOG" \
  "$DEBUG_STRING_LIB_SOURCE" "$DEBUG_STRING_MAIN_SOURCE" "$DEBUG_STRING_OUTPUT_WASM" \
  "$DEBUG_STRING_OUTPUT_RUN_LOG"
rm -rf "$DEBUG_OUTPUT_DIR" "$DEBUG_STRING_OUTPUT_DIR"

STAGE1_CORE_WASM="$(VIBE_CLI_CORE_OUT_DIR="$OUT_DIR" \
  VIBE_CLI_CORE_HOST_MODE="$HOST_MODE" \
  VIBE_CLI_CORE_REBUILD=always \
  VIBE_WASM_PRE_GROW_PAGES="$BUILD_PRE_GROW_PAGES" \
  ENTRY_PATH="$ENTRY_PATH" \
  STAGE1_CORE_WASM="$STAGE1_CORE_WASM" \
  bash "$PROJECT_ROOT/scripts/build_cli_core.sh")" || exit $?

cat >"$INPUT_SOURCE" <<'EOF'
export let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> sample wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    "${INPUT_SOURCE#$PROJECT_ROOT/}" \
    "${OUTPUT_WASM#$PROJECT_ROOT/}" \
    "$ENTRY_NAME" || exit $?

unset VIBE_PREOPEN_DIR

if [ ! -f "$OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: sample wasm not produced" >&2
  exit 1
fi

output_magic="$(od -An -t x1 -N 4 "$OUTPUT_WASM" | tr -d ' \n')"
if [ "$output_magic" != "0061736d" ]; then
  echo "selfhost cli core gate failed: sample artifact is not wasm (magic=$output_magic)" >&2
  exit 1
fi

run_stage_capture_stdout "run sample wasm produced by selfhost core cli" \
  "$OUTPUT_RUN_LOG" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$OUTPUT_WASM" || exit $?

sample_result="$(grep -E '^-?[0-9]+$' "$OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$sample_result" ]; then
  echo "selfhost cli core gate failed: compiled sample returned no numeric result" >&2
  exit 1
fi

if [ "$sample_result" != "42" ]; then
  echo "selfhost cli core gate failed: compiled sample returned '$sample_result' (expected 42)" >&2
  exit 1
fi

cat >"$COMMAND_INPUT_SOURCE" <<'EOF'
export let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style compile-lite wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    compile-lite \
    --wasm \
    --entry "$ENTRY_NAME" \
    --profile-tsv "${COMMAND_PROFILE_TSV#$PROJECT_ROOT/}" \
    --profile-callstack "${COMMAND_CALLSTACK_TSV#$PROJECT_ROOT/}" \
    "${COMMAND_INPUT_SOURCE#$PROJECT_ROOT/}" \
    -o "${COMMAND_OUTPUT_WASM#$PROJECT_ROOT/}" || exit $?

unset VIBE_PREOPEN_DIR

if [ ! -f "$COMMAND_OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: command-style compile-lite wasm not produced" >&2
  exit 1
fi
if [ ! -f "$COMMAND_PROFILE_TSV" ] || ! grep -Eq $'^total\t[0-9]+\t[1-9][0-9]*$' "$COMMAND_PROFILE_TSV"; then
  echo "selfhost cli core gate failed: command-style compile-lite profile tsv not produced" >&2
  exit 1
fi
if ! grep -Eq $'^parse\t[0-9]+\t[0-9]+$' "$COMMAND_PROFILE_TSV"; then
  echo "selfhost cli core gate failed: command-style compile-lite parse profile stage missing" >&2
  exit 1
fi
if ! grep -Eq $'^write\t[0-9]+\t[1-9][0-9]*$' "$COMMAND_PROFILE_TSV"; then
  echo "selfhost cli core gate failed: command-style compile-lite internal write profile missing" >&2
  exit 1
fi
if [ ! -f "$COMMAND_CALLSTACK_TSV" ] || ! grep -Eq $'^compile\t[0-9]+\t[1-9][0-9]*$' "$COMMAND_CALLSTACK_TSV"; then
  echo "selfhost cli core gate failed: command-style compile-lite callstack profile not produced" >&2
  exit 1
fi

run_wasm_validate "validate command-style compile-lite wasm" "$COMMAND_OUTPUT_WASM" || exit $?

run_stage_capture_stdout "run command-style compile-lite wasm produced by selfhost core cli" \
  "$COMMAND_OUTPUT_RUN_LOG" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$COMMAND_OUTPUT_WASM" || exit $?

command_result="$(grep -E '^-?[0-9]+$' "$COMMAND_OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$command_result" ]; then
  echo "selfhost cli core gate failed: command-style compile-lite sample returned no numeric result" >&2
  exit 1
fi

if [ "$command_result" != "42" ]; then
  echo "selfhost cli core gate failed: command-style compile-lite sample returned '$command_result' (expected 42)" >&2
  exit 1
fi

cat >"$COMPILE_COMMAND_INPUT_SOURCE" <<'EOF'
export let _start = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style compile wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    compile \
    --wasm \
    "${COMPILE_COMMAND_INPUT_SOURCE#$PROJECT_ROOT/}" \
    -o "${COMPILE_COMMAND_OUTPUT_WASM#$PROJECT_ROOT/}" || exit $?

unset VIBE_PREOPEN_DIR

if [ ! -f "$COMPILE_COMMAND_OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: command-style compile wasm not produced" >&2
  exit 1
fi

run_wasm_validate "validate command-style compile wasm" "$COMPILE_COMMAND_OUTPUT_WASM" || exit $?

run_stage_capture_stdout "run command-style compile wasm produced by selfhost core cli" \
  "$COMPILE_COMMAND_OUTPUT_RUN_LOG" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$COMPILE_COMMAND_OUTPUT_WASM" || exit $?

compile_command_result="$(grep -E '^-?[0-9]+$' "$COMPILE_COMMAND_OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$compile_command_result" ]; then
  echo "selfhost cli core gate failed: command-style compile sample returned no numeric result" >&2
  exit 1
fi

if [ "$compile_command_result" != "42" ]; then
  echo "selfhost cli core gate failed: command-style compile sample returned '$compile_command_result' (expected 42)" >&2
  exit 1
fi

cat >"$BUILD_COMMAND_INPUT_SOURCE" <<'EOF'
export let _start = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style build release wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    build \
    --release \
    "${BUILD_COMMAND_INPUT_SOURCE#$PROJECT_ROOT/}" \
    -o "${BUILD_COMMAND_OUTPUT_WASM#$PROJECT_ROOT/}" || exit $?

unset VIBE_PREOPEN_DIR

if [ ! -f "$BUILD_COMMAND_OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: command-style build wasm not produced" >&2
  exit 1
fi

run_wasm_validate "validate command-style build wasm" "$BUILD_COMMAND_OUTPUT_WASM" || exit $?

run_stage_capture_stdout "run command-style build wasm produced by selfhost core cli" \
  "$BUILD_COMMAND_OUTPUT_RUN_LOG" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$BUILD_COMMAND_OUTPUT_WASM" || exit $?

build_command_result="$(grep -E '^-?[0-9]+$' "$BUILD_COMMAND_OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$build_command_result" ]; then
  echo "selfhost cli core gate failed: command-style build sample returned no numeric result" >&2
  exit 1
fi

if [ "$build_command_result" != "42" ]; then
  echo "selfhost cli core gate failed: command-style build sample returned '$build_command_result' (expected 42)" >&2
  exit 1
fi

cat >"$CHECK_COMMAND_INPUT_SOURCE" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style check" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    check \
    --profile-tsv "${CHECK_COMMAND_PROFILE_TSV#$PROJECT_ROOT/}" \
    --profile-callstack "${CHECK_COMMAND_CALLSTACK_TSV#$PROJECT_ROOT/}" \
    "${CHECK_COMMAND_INPUT_SOURCE#$PROJECT_ROOT/}" || exit $?

unset VIBE_PREOPEN_DIR

if [ ! -f "$CHECK_COMMAND_PROFILE_TSV" ] || ! grep -Eq $'^total\t[0-9]+\t[1-9][0-9]*$' "$CHECK_COMMAND_PROFILE_TSV"; then
  echo "selfhost cli core gate failed: command-style check profile tsv not produced" >&2
  exit 1
fi
if [ ! -f "$CHECK_COMMAND_CALLSTACK_TSV" ] || ! grep -Eq $'^check\t[0-9]+\t[1-9][0-9]*$' "$CHECK_COMMAND_CALLSTACK_TSV"; then
  echo "selfhost cli core gate failed: command-style check callstack profile not produced" >&2
  exit 1
fi

cat >"$DEBUG_LIB_SOURCE" <<'EOF'
export let helper = (a: Int, b: Int) -> Int { a + b }
EOF

cat >"$DEBUG_MAIN_SOURCE" <<'EOF'
import ./core_debug_lib.vibe { helper }
let answer = () -> Int { helper(19, 23) }
EOF

run_stage "stage1 core artifact -> linked debug wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke _start \
  "$STAGE1_CORE_WASM" \
  "${DEBUG_MAIN_SOURCE#$PROJECT_ROOT/}" \
  "${DEBUG_OUTPUT_WASM#$PROJECT_ROOT/}" \
  "$ENTRY_NAME" \
  debug || exit $?

if [ ! -f "$DEBUG_OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: linked debug wasm not produced" >&2
  exit 1
fi

if [ ! -f "$DEBUG_LIB_WASM" ]; then
  echo "selfhost cli core gate failed: linked debug library wasm not produced" >&2
  exit 1
fi

run_wasm_validate "validate linked debug main wasm" "$DEBUG_OUTPUT_WASM" || exit $?
run_wasm_validate "validate linked debug library wasm" "$DEBUG_LIB_WASM" || exit $?

run_stage_capture_stdout "run linked debug wasm produced by selfhost core cli" \
  "$DEBUG_OUTPUT_RUN_LOG" \
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
  "$WASMTIME_RUN" run --preload core_debug_lib="$DEBUG_LIB_WASM" --invoke _start "$DEBUG_OUTPUT_WASM" || exit $?

debug_result="$(grep -E '^-?[0-9]+$' "$DEBUG_OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$debug_result" ]; then
  echo "selfhost cli core gate failed: linked debug sample returned no numeric result" >&2
  exit 1
fi

if [ "$debug_result" != "42" ]; then
  echo "selfhost cli core gate failed: linked debug sample returned '$debug_result' (expected 42)" >&2
  exit 1
fi

cat >"$DEBUG_STRING_LIB_SOURCE" <<'EOF'
export let helper = () -> String { "Hello" }
EOF

cat >"$DEBUG_STRING_MAIN_SOURCE" <<'EOF'
import ./core_debug_string_lib.vibe { helper }
export let answer = () -> Int { String::length(String::concat(helper(), ", world")) }
EOF

run_stage "stage1 core artifact -> linked debug string wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke _start \
  "$STAGE1_CORE_WASM" \
  "${DEBUG_STRING_MAIN_SOURCE#$PROJECT_ROOT/}" \
  "${DEBUG_STRING_OUTPUT_WASM#$PROJECT_ROOT/}" \
  "$ENTRY_NAME" \
  debug || exit $?

if [ ! -f "$DEBUG_STRING_OUTPUT_WASM" ]; then
  echo "selfhost cli core gate failed: linked debug string wasm not produced" >&2
  exit 1
fi

if [ ! -f "$DEBUG_STRING_LIB_WASM" ]; then
  echo "selfhost cli core gate failed: linked debug string library wasm not produced" >&2
  exit 1
fi

run_wasm_validate "validate linked debug string main wasm" "$DEBUG_STRING_OUTPUT_WASM" || exit $?
run_wasm_validate "validate linked debug string library wasm" "$DEBUG_STRING_LIB_WASM" || exit $?

run_stage_capture_stdout "run linked debug string wasm produced by selfhost core cli" \
  "$DEBUG_STRING_OUTPUT_RUN_LOG" \
  env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
  "$WASMTIME_RUN" run --preload core_debug_string_lib="$DEBUG_STRING_LIB_WASM" --invoke _start "$DEBUG_STRING_OUTPUT_WASM" || exit $?

debug_string_result="$(grep -E '^-?[0-9]+$' "$DEBUG_STRING_OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$debug_string_result" ]; then
  echo "selfhost cli core gate failed: linked debug string sample returned no numeric result" >&2
  exit 1
fi

if [ "$debug_string_result" != "12" ]; then
  echo "selfhost cli core gate failed: linked debug string sample returned '$debug_string_result' (expected 12)" >&2
  exit 1
fi

echo "selfhost cli core gate passed"

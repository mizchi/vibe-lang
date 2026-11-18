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

# One portable bound for every stage (#2958): timeout, else gtimeout, else a
# process-group watchdog that answers 124 only when IT fired. The local copy
# this replaced mapped any 143/137 to 124, so a stage the OOM killer took was
# reported as a timeout, and it signalled only the direct child. 0 still
# means "no bound".
. "$SCRIPT_DIR/run_bounded.sh"
run_with_timeout() { run_bounded "$@"; }

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

# `--entry` is spelled out rather than leaning on a default. The two front
# doors disagreed about it: `runtime/vibe compile foo.vibe` defaulted to `main`
# while this CLI's own `compile` verb defaulted to `_start`, so the same
# command meant two entries depending on which door was used. The doors are one
# door now (lib/@vibe/cli/user_dispatch.vibe) and it keeps the LAUNCHER's
# `main`, which is the contract users see. What this gate is asking -- can the
# CLI core compile a source into a runnable artifact -- does not depend on
# which default won, so it names the entry and stops depending on it.
cat >"$COMPILE_COMMAND_INPUT_SOURCE" <<'EOF'
export let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style compile wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    compile \
    --wasm \
    --entry "$ENTRY_NAME" \
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

# Same reason as the compile fixture above: name the entry.
cat >"$BUILD_COMMAND_INPUT_SOURCE" <<'EOF'
export let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"

run_stage "stage1 core artifact -> command-style build release wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
    --invoke _start \
    "$STAGE1_CORE_WASM" \
    build \
    --release \
    --entry "$ENTRY_NAME" \
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
export let helper = (a: Int, b: Int) -> Int { a * 100 + b }
EOF

cat >"$DEBUG_MAIN_SOURCE" <<'EOF'
import ./core_debug_lib.vibe { helper }
let answer = () -> Int { helper(a = 19, b = 23) }
EOF

# Fresh processes share only the cache. A warm prelude verdict plus a cached
# TypeEnv used to leave the imported call without its checked argument slots.
check_linked_debug_replay() {
  local entry_source=$1 final_main=$2 final_lib=$3
  local phase main_wasm lib_wasm
  local debug_cold
  debug_cold=$(mktemp -d "$OUT_DIR/core_debug_cold.XXXXXX")
  mkdir -p "$debug_cold/cache"
  for phase in cold warm; do
    if [ "$phase" = cold ]; then
      main_wasm="$debug_cold/entry.wasm"
      lib_wasm="$debug_cold/entry.debug/core_debug_lib.wasm"
    else
      main_wasm="$final_main"
      lib_wasm="$final_lib"
    fi
    run_stage "linked debug compile ($phase)" \
      env VIBE_BUILD_CACHE_DIR="${debug_cold#$PROJECT_ROOT/}/cache" VIBE_LINKED_OUTPUT_MEMO=on VIBE_DEBUG_ENV=1 \
      bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$STAGE1_CORE_WASM" \
      "${entry_source#$PROJECT_ROOT/}" "${main_wasm#$PROJECT_ROOT/}" "$ENTRY_NAME" debug 2>"$debug_cold/$phase.log" || {
        grep -vF '[env-get]' "$debug_cold/$phase.log" >&2 || true
        exit 1
      }
    if grep -Fq '[env-get] VIBE_PROFILE_MEMORY_MARK:linked_output_memo_hit=' "$debug_cold/$phase.log"; then
      [ "$phase" = warm ] || { echo "cold linked debug build unexpectedly hit the memo" >&2; exit 1; }
    elif [ "$phase" = warm ]; then
      echo "warm linked debug build did not exercise verdict replay" >&2
      exit 1
    fi
    run_wasm_validate "validate linked debug main ($phase)" "$main_wasm" || exit $?
    run_wasm_validate "validate linked debug library ($phase)" "$lib_wasm" || exit $?
    run_stage_capture_stdout "execute linked debug main ($phase)" "$DEBUG_OUTPUT_RUN_LOG" \
      env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
      "$WASMTIME_RUN" run --preload core_debug_lib="$lib_wasm" --invoke _start "$main_wasm" || exit $?
    if ! grep -Fxq '1923' "$DEBUG_OUTPUT_RUN_LOG"; then
      echo "selfhost cli core gate failed: linked debug $phase expected 1923" >&2
      exit 1
    fi
  done
  cmp "$debug_cold/entry.wasm" "$final_main" || return 1
  cmp "$debug_cold/entry.debug/core_debug_lib.wasm" "$final_lib" || return 1
  rm -rf "$debug_cold"
}

check_linked_debug_replay "$DEBUG_MAIN_SOURCE" "$DEBUG_OUTPUT_WASM" "$DEBUG_LIB_WASM"

# The checker prepends this package's shared scope to its sibling. The call
# into the explicit Wasm library now sits at a different byte offset.
debug_pkg=$(mktemp -d "$OUT_DIR/core_debug_shared.XXXXXX")
printf 'import @vibe/random { seed }\n' > "$debug_pkg/index.vpkg"
cp "$DEBUG_LIB_SOURCE" "$debug_pkg/core_debug_lib.vibe"
cp "$DEBUG_MAIN_SOURCE" "$debug_pkg/entry.vibe"
check_linked_debug_replay "$debug_pkg/entry.vibe" "$debug_pkg/result.wasm" "$debug_pkg/result.debug/core_debug_lib.wasm"
rm -rf "$debug_pkg"

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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_cli_adapter"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/index.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_CLI_ADAPTER_STAGE_TIMEOUT_SEC:-300}"
STAGE1_CORE_WASM="$OUT_DIR/index_stage1.wasm"
STAGE1_CLI_WASM="$OUT_DIR/selfhost_cli_stage1.wasm"
INPUT_SOURCE="$OUT_DIR/adapter_env_input.vibe"
OUTPUT_WASM="$OUT_DIR/adapter_env_output.wasm"
OUTPUT_RUN_LOG="$OUT_DIR/adapter_output_run.log"
ENTRY_NAME="answer"
VIBE_NODE_WASM_FLAGS="${VIBE_NODE_WASM_FLAGS:---experimental-wasm-exnref}"
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"

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
  echo "[selfhost-cli] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

run_stage_capture_stdout() {
  local name="$1"
  local out_path="$2"
  shift 2
  echo "[selfhost-cli] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@" >"$out_path"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

mkdir -p "$OUT_DIR"
rm -f "$STAGE1_CORE_WASM" "$STAGE1_CLI_WASM" "$OUTPUT_WASM" "$OUTPUT_RUN_LOG"

if ! command -v node >/dev/null 2>&1; then
  echo "selfhost cli adapter gate failed: node not found" >&2
  exit 1
fi

if [ ! -f "$PROJECT_ROOT/scripts/wasm_vibe_host_runner.js" ]; then
  echo "selfhost cli adapter gate failed: wasm host runner not found: $PROJECT_ROOT/scripts/wasm_vibe_host_runner.js" >&2
  exit 1
fi

if [ ! -f "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" ]; then
  echo "selfhost cli adapter gate failed: wasm host runner wrapper not found: $PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" >&2
  exit 1
fi

if [ -x "$HOST_VIBE_EXE" ]; then
  HOST_COMPILE_CMD=("$HOST_VIBE_EXE" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE_CMD=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

run_stage "stage0 host compiler -> stage1 selfhost compiler core wasm" \
  "${HOST_COMPILE_CMD[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM"

cat >"$INPUT_SOURCE" <<'EOF'
let answer = () -> Int { 40 + 2 }
EOF

export VIBE_PREOPEN_DIR="$PROJECT_ROOT"
run_stage "stage1 index artifact -> selfhost cli wasm" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke selfbuild_compile_cli_adapter "$STAGE1_CORE_WASM"

if [ ! -f "$STAGE1_CLI_WASM" ]; then
  echo "selfhost cli adapter gate failed: stage1 cli artifact was not produced" >&2
  exit 1
fi

stage1_cli_magic="$(od -An -t x1 -N 4 "$STAGE1_CLI_WASM" | tr -d ' \n')"
if [ "$stage1_cli_magic" != "0061736d" ]; then
  echo "selfhost cli adapter gate failed: stage1 cli artifact is not wasm (magic=$stage1_cli_magic)" >&2
  exit 1
fi

run_stage "stage1 selfhost cli artifact -> sample wasm compile" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke run "$STAGE1_CLI_WASM" \
    "${INPUT_SOURCE#$PROJECT_ROOT/}" \
    "${OUTPUT_WASM#$PROJECT_ROOT/}" \
    "$ENTRY_NAME"
unset VIBE_PREOPEN_DIR

if [ ! -f "$OUTPUT_WASM" ]; then
  echo "selfhost cli adapter gate failed: sample wasm not produced" >&2
  exit 1
fi

output_magic="$(od -An -t x1 -N 4 "$OUTPUT_WASM" | tr -d ' \n')"
if [ "$output_magic" != "0061736d" ]; then
  echo "selfhost cli adapter gate failed: sample artifact is not wasm (magic=$output_magic)" >&2
  exit 1
fi

run_stage_capture_stdout "run sample wasm produced by selfhost cli" \
  "$OUTPUT_RUN_LOG" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" --invoke run "$OUTPUT_WASM"

sample_tagged="$(grep -E '^-?[0-9]+$' "$OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$sample_tagged" ]; then
  echo "selfhost cli adapter gate failed: compiled sample returned no numeric result" >&2
  exit 1
fi

sample_result="$sample_tagged"
if [ "$sample_result" != "42" ]; then
  echo "selfhost cli adapter gate failed: compiled sample returned '$sample_result' (tagged=$sample_tagged, expected 42)" >&2
  exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Selfhost CLI Adapter Gate"
    echo
    echo "- stage1 index artifact produced a selfhost CLI wasm via selfbuild_compile_cli_adapter"
    echo "- the generated selfhost CLI wasm compiled a real input file via JS Preview2 host execution"
    echo "- adapter input/output/entry were supplied via argv through Env::args_len / Env::args_get"
    echo "- env variables remain compatibility fallback only"
    echo "- no seed compiler or MoonBit host was used after stage1 core wasm creation"
    echo "- compiled sample output returned \`42\` via artifact-only execution"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

echo "selfhost cli adapter gate passed"

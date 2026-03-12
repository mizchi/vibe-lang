#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$PROJECT_ROOT/_build/bench/selfhost_cli_component_preview2"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/compiler/selfhost_cli_component_entry.vibe}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_CLI_COMPONENT_PREVIEW2_STAGE_TIMEOUT_SEC:-300}"
COMPONENT_PATH="$OUT_DIR/selfhost_cli_component_preview2.component.wasm"
OUTPUT_WASM="$OUT_DIR/selfhost_cli_component_preview2_output.wasm"
OUTPUT_RUN_LOG="$OUT_DIR/selfhost_cli_component_preview2_run.log"
INPUT_SOURCE='let answer = () -> Int { 40 + 2 }'
ENTRY_NAME='answer'
COMPONENT_EXPORT_NAME='compile-cli-request'
HOST_VIBE_EXE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
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
  echo "[selfhost-cli-component-preview2] $name"
  set +e
  run_with_timeout "$STAGE_TIMEOUT_SEC" "$@"
  local status=$?
  set -e
  if [ "$status" -eq 124 ]; then
    echo "[selfhost-cli-component-preview2] timeout: $name (${STAGE_TIMEOUT_SEC}s)" >&2
  fi
  if [ "$status" -ne 0 ]; then
    return "$status"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

release_binary_is_fresh() {
  if [ ! -x "$HOST_VIBE_EXE" ]; then
    return 1
  fi
  [ "$HOST_VIBE_EXE" -nt "$ENTRY_PATH" ] &&
    [ "$HOST_VIBE_EXE" -nt "$PROJECT_ROOT/src/runtime_compile/compile.mbt" ] &&
    [ "$HOST_VIBE_EXE" -nt "$PROJECT_ROOT/src/codegen/component_codegen.mbt" ]
}

invoke_component_request() {
  local request="$1"
  local raw
  raw="$(
    env VIBE_WASMTIME_WASM_FLAGS="$WASMTIME_WASM_FLAGS" \
      "$WASMTIME_RUN" \
      --invoke "$COMPONENT_EXPORT_NAME(\"$INPUT_SOURCE\",\"$request\")" \
      "$COMPONENT_PATH" | grep -E '^-?[0-9]+$' | tail -n 1 || true
  )"
  if [ -z "$raw" ]; then
    echo "component returned no numeric result for request '$request'" >&2
    return 1
  fi
  echo $((raw / 4))
}

mkdir -p "$OUT_DIR"
rm -f "$COMPONENT_PATH" "$OUTPUT_WASM" "$OUTPUT_RUN_LOG"

require_cmd wasm-tools
require_cmd python3

HOST_COMPILE_CMD=("$HOST_VIBE_EXE" compile --component-string-lift)
REBUILD_RELEASE_CMD=(moon build --target native --release --warn-list '-29-55-67-23-24-7-1' src/cmd/vibe)

if release_binary_is_fresh; then
  run_stage "host compiler -> selfhost cli preview2 component" \
    "${HOST_COMPILE_CMD[@]}" "$ENTRY_PATH" -o "$COMPONENT_PATH"
else
  run_stage "rebuild release vibe for preview2 component gate" "${REBUILD_RELEASE_CMD[@]}"
  run_stage "host compiler -> selfhost cli preview2 component" \
    "${HOST_COMPILE_CMD[@]}" "$ENTRY_PATH" -o "$COMPONENT_PATH"
fi

run_stage "validate preview2 component" wasm-tools validate --features exceptions "$COMPONENT_PATH"

component_len="$(invoke_component_request "len:$ENTRY_NAME")"
if [ "$component_len" -le 8 ]; then
  echo "selfhost cli component preview2 gate failed: compiled wasm length too small ($component_len)" >&2
  exit 1
fi

chunk_count=$(((component_len + 6) / 7))
remaining="$component_len"
: >"$OUTPUT_WASM"
for ((chunk_index = 0; chunk_index < chunk_count; chunk_index++)); do
  packed="$(invoke_component_request "chunk:$ENTRY_NAME:$chunk_index")"
  python3 - "$packed" "$remaining" "$OUTPUT_WASM" <<'PY'
import pathlib
import sys

packed = int(sys.argv[1])
remaining = int(sys.argv[2])
path = pathlib.Path(sys.argv[3])
count = 7 if remaining >= 7 else remaining
data = bytes((packed >> (8 * i)) & 0xFF for i in range(count))
with path.open("ab") as fh:
    fh.write(data)
PY
  remaining=$((remaining - 7))
done

output_magic="$(od -An -t x1 -N 4 "$OUTPUT_WASM" | tr -d ' \n')"
if [ "$output_magic" != "0061736d" ]; then
  echo "selfhost cli component preview2 gate failed: sample artifact is not wasm (magic=$output_magic)" >&2
  exit 1
fi

run_stage "validate compiled sample wasm" wasm-tools validate "$OUTPUT_WASM"

run_stage "run sample wasm produced by preview2 component selfhost cli" \
  bash -lc "env VIBE_WASMTIME_WASM_FLAGS='$WASMTIME_WASM_FLAGS' '$WASMTIME_RUN' --invoke run '$OUTPUT_WASM' >'$OUTPUT_RUN_LOG'"

sample_result="$(grep -E '^-?[0-9]+$' "$OUTPUT_RUN_LOG" | tail -n 1 || true)"
if [ -z "$sample_result" ]; then
  echo "selfhost cli component preview2 gate failed: compiled sample returned no numeric result" >&2
  exit 1
fi

if [ "$sample_result" != "42" ]; then
  echo "selfhost cli component preview2 gate failed: compiled sample returned '$sample_result' (expected 42)" >&2
  exit 1
fi

echo "selfhost cli component preview2 gate passed"

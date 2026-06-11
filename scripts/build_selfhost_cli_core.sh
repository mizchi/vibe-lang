#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_SELFHOST_CLI_CORE_OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_core}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/vibe/cli/selfhost_entry.vibe}"
STAGE1_CORE_WASM="${STAGE1_CORE_WASM:-$OUT_DIR/index_stage1.wasm}"
HOST_MODE="${VIBE_SELFHOST_CLI_CORE_HOST_MODE:-debug}"
REBUILD_MODE="${VIBE_SELFHOST_CLI_CORE_REBUILD:-auto}"
STAGE_TIMEOUT_SEC="${VIBE_SELFHOST_CLI_CORE_STAGE_TIMEOUT_SEC:-300}"

HOST_VIBE_EXE_RELEASE="$PROJECT_ROOT/_build/native/release/build/cmd/vibe/vibe.exe"
HOST_VIBE_EXE_DEBUG="$PROJECT_ROOT/_build/native/debug/build/cmd/vibe/vibe.exe"

case "$HOST_MODE" in
  debug|release) ;;
  *) echo "build-selfhost-cli-core: VIBE_SELFHOST_CLI_CORE_HOST_MODE must be debug|release" >&2; exit 1 ;;
esac

case "$REBUILD_MODE" in
  auto|always|never) ;;
  *) echo "build-selfhost-cli-core: VIBE_SELFHOST_CLI_CORE_REBUILD must be auto|always|never" >&2; exit 1 ;;
esac

if [ ! -f "$ENTRY_PATH" ]; then
  echo "build-selfhost-cli-core: entry not found: $ENTRY_PATH" >&2
  exit 1
fi

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

source_changed_since() {
  local artifact="$1"
  [ -f "$artifact" ] || return 0
  find "$PROJECT_ROOT/vibe" -type f -name '*.vibe' -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT/src" -type f \( -name '*.mbt' -o -name 'moon.pkg' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT/scripts" -maxdepth 1 -type f \( -name 'build_selfhost_cli_core.sh' -o -name 'ensure_native_cli.sh' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT" -maxdepth 1 -type f \( -name 'moon.mod' -o -name 'moon.mod.json' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q .
}

needs_rebuild=0
if [ "$REBUILD_MODE" = "always" ]; then
  needs_rebuild=1
elif [ "$REBUILD_MODE" = "auto" ] && source_changed_since "$STAGE1_CORE_WASM"; then
  needs_rebuild=1
fi

if [ ! -f "$STAGE1_CORE_WASM" ] && [ "$REBUILD_MODE" = "never" ]; then
  echo "build-selfhost-cli-core: artifact missing and rebuild disabled: $STAGE1_CORE_WASM" >&2
  exit 1
fi

if [ "$needs_rebuild" -eq 0 ]; then
  printf '%s\n' "$STAGE1_CORE_WASM"
  exit 0
fi

mkdir -p "$(dirname "$STAGE1_CORE_WASM")"

if [ -n "${VIBE_BIN:-}" ]; then
  if [ ! -x "$VIBE_BIN" ]; then
    echo "build-selfhost-cli-core: VIBE_BIN is not executable: $VIBE_BIN" >&2
    exit 1
  fi
  HOST_COMPILE_CMD=("$VIBE_BIN" compile --wasm --force-cabi-realloc)
elif [ "$HOST_MODE" = "release" ]; then
  VIBE_CLI_RELEASE=1 source "$PROJECT_ROOT/scripts/ensure_native_cli.sh"
  HOST_COMPILE_CMD=("$VIBE_CLI_BIN" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_DEBUG" ]; then
  HOST_COMPILE_CMD=("$HOST_VIBE_EXE_DEBUG" compile --wasm --force-cabi-realloc)
elif [ -x "$HOST_VIBE_EXE_RELEASE" ]; then
  HOST_COMPILE_CMD=("$HOST_VIBE_EXE_RELEASE" compile --wasm --force-cabi-realloc)
else
  HOST_COMPILE_CMD=(moon run --target native src/cmd/vibe -- compile --wasm --force-cabi-realloc)
fi

echo "[selfhost-cli-core] stage0 host compiler -> stage1 selfhost compiler core wasm" >&2
set +e
run_with_timeout "$STAGE_TIMEOUT_SEC" "${HOST_COMPILE_CMD[@]}" "$ENTRY_PATH" -o "$STAGE1_CORE_WASM" >&2
status=$?
set -e
if [ "$status" -eq 124 ]; then
  echo "[selfhost-cli-core] timeout: stage0 host compiler -> stage1 selfhost compiler core wasm (${STAGE_TIMEOUT_SEC}s)" >&2
fi
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

if [ ! -f "$STAGE1_CORE_WASM" ]; then
  echo "build-selfhost-cli-core: artifact not produced: $STAGE1_CORE_WASM" >&2
  exit 1
fi

magic="$(od -An -t x1 -N 4 "$STAGE1_CORE_WASM" | tr -d ' \n')"
if [ "$magic" != "0061736d" ]; then
  echo "build-selfhost-cli-core: artifact is not wasm (magic=$magic): $STAGE1_CORE_WASM" >&2
  exit 1
fi

printf '%s\n' "$STAGE1_CORE_WASM"

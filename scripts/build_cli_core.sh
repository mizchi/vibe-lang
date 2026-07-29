#!/usr/bin/env bash
# Moon-free reconstruction of the script deleted in 8ba3aa79 ("chore: prune
# dead MoonBit-host scaffolding after src/ removal (#596)"). That deletion
# happened the same day src/ (the MoonBit host) was retired, but
# scripts/vibe_cli.sh and scripts/test_cli_core.sh were never updated and
# still call this file by name -- see #766 / #804 / #821 / #894.
#
# Historically this script used an already-built *host* `vibe` compiler
# (MoonBit `moon run ... src/cmd/vibe -- compile ...`, or a native `VIBE_BIN`)
# to compile an entry `.vibe` file into the selfhost CLI's "core" wasm. With
# src/ gone there is no host compiler left; the equivalent is to use
# an already-built *selfhost* compiler wasm (produced via the
# bootstrap seed -> stage1 -> stage2 pipeline, scripts/generations.sh --
# the same machinery scripts/build_cli_wasm.sh uses for dist/cli/vibe-cli.wasm)
# to compile the entry file instead.
#
# ENTRY_PATH defaults to lib/@vibe/cli/main.vibex (#1137 stage 1) -- the
# ordinary ADR-0075 `.vibex` entry that wraps the split CLI's subcommand
# dispatcher (compile / build / check / compile-lite / serve, plus a
# low_level_cli_main positional fallback for callers that pass
# `<input> <output> <entry_name> [mode]` directly; see
# lib/@vibe/cli/dispatch.vibe::selfhost_cli_dispatch_args) in a real `fn main`
# and turns its Int result into a process exit code. Compiled with
# entry_name=main, the output wasm exports the WASI `_start` convention gives
# every `.vibex` program, run via `--invoke _start` (scripts/vibe_cli.sh) --
# not the raw `--invoke cli_main` ABI this script used before #1137. Compiling
# it needs import resolution from the filesystem, which the base compiler's
# cli_main only does under VIBE_FS_COMPILE=1 (lib/@vibe/compiler/cli_adapter.vibe).
#
# Prints the resulting wasm path to stdout on success (mirrors the deleted
# script's contract -- callers capture it via command substitution).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

OUT_DIR="${VIBE_CLI_CORE_OUT_DIR:-$PROJECT_ROOT/_build/bench/selfhost_cli_core}"
ENTRY_PATH="${ENTRY_PATH:-$PROJECT_ROOT/lib/@vibe/cli/main.vibex}"
STAGE1_CORE_WASM="${STAGE1_CORE_WASM:-$OUT_DIR/index_stage1.wasm}"
HOST_MODE="${VIBE_CLI_CORE_HOST_MODE:-debug}"
REBUILD_MODE="${VIBE_CLI_CORE_REBUILD:-auto}"
STAGE_TIMEOUT_SEC="${VIBE_CLI_CORE_STAGE_TIMEOUT_SEC:-300}"
# Skip rebuilding the base selfhost compiler when a known-good one is already
# on hand (e.g. from a prior `pkf run full-gate`/`build_cli_wasm.sh` run).
BASE_COMPILER="${VIBE_CLI_CORE_BASE_COMPILER:-}"

case "$HOST_MODE" in
  debug|release) ;;
  *) echo "build-selfhost-cli-core: VIBE_CLI_CORE_HOST_MODE must be debug|release" >&2; exit 1 ;;
esac

case "$REBUILD_MODE" in
  auto|always|never) ;;
  *) echo "build-selfhost-cli-core: VIBE_CLI_CORE_REBUILD must be auto|always|never" >&2; exit 1 ;;
esac

if [ ! -f "$ENTRY_PATH" ]; then
  echo "build-selfhost-cli-core: entry not found: $ENTRY_PATH" >&2
  exit 1
fi

rel_path() {
  local path="$1"
  case "$path" in
    "$PROJECT_ROOT"/*) printf '%s\n' "${path#$PROJECT_ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

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
  find "$PROJECT_ROOT/lib" -type f \( -name '*.vibe' -o -name '*.vibex' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT/scripts" -maxdepth 1 -type f \( -name 'build_cli_core.sh' -o -name 'build_cli_wasm.sh' -o -name 'generations.sh' \) -newer "$artifact" -print -quit 2>/dev/null | grep -q . ||
    find "$PROJECT_ROOT/bootstrap" -maxdepth 2 -type f -name 'seed.json' -newer "$artifact" -print -quit 2>/dev/null | grep -q .
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

# Base compiler: an already-built selfhost compiler wasm, used to
# compile ENTRY_PATH. HOST_MODE is accepted (and validated) for interface
# compatibility with the retired moon-host script, but there is no separate
# debug/release selfhost compiler build to pick between -- both modes build
# the same way.
if [ -z "$BASE_COMPILER" ]; then
  short_sha="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
  cached="$(ls -t "$PROJECT_ROOT"/_build/selfhost/generations/*_"$short_sha"/stage2.wasm 2>/dev/null | head -1 || true)"
  # #895 review: the commit-sha directory name alone doesn't prove the cached
  # stage2.wasm reflects the CURRENT tree -- a dirty working copy (uncommitted
  # edits under lib/, or to the build scripts/seed.json) keeps the same
  # short_sha, so also require it pass the same source_changed_since
  # freshness check used for STAGE1_CORE_WASM above before trusting it.
  if [ -n "$cached" ] && [ -s "$cached" ] && ! source_changed_since "$cached"; then
    BASE_COMPILER="$cached"
    echo "[selfhost-cli-core] reusing base selfhost compiler: $(rel_path "$BASE_COMPILER")" >&2
  else
    echo "[selfhost-cli-core] building base selfhost compiler (seed -> stage1 -> stage2)" >&2
    BASE_COMPILER="$OUT_DIR/base_compiler.wasm"
    set +e
    run_with_timeout "$STAGE_TIMEOUT_SEC" bash "$PROJECT_ROOT/scripts/build_cli_wasm.sh" "$BASE_COMPILER" >&2
    status=$?
    set -e
    if [ "$status" -eq 124 ]; then
      echo "[selfhost-cli-core] timeout: building base selfhost compiler (${STAGE_TIMEOUT_SEC}s)" >&2
    fi
    if [ "$status" -ne 0 ]; then
      exit "$status"
    fi
  fi
fi

if [ ! -f "$BASE_COMPILER" ]; then
  echo "build-selfhost-cli-core: base compiler not found: $BASE_COMPILER" >&2
  exit 1
fi

echo "[selfhost-cli-core] base selfhost compiler -> stage1 selfhost CLI core wasm" >&2
set +e
VIBE_PREOPEN_DIR="$PROJECT_ROOT" VIBE_FS_COMPILE=1 \
  run_with_timeout "$STAGE_TIMEOUT_SEC" \
  bash "$PROJECT_ROOT/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main \
  "$BASE_COMPILER" \
  "$(rel_path "$ENTRY_PATH")" \
  "$(rel_path "$STAGE1_CORE_WASM")" \
  main >&2
status=$?
set -e
if [ "$status" -eq 124 ]; then
  echo "[selfhost-cli-core] timeout: base selfhost compiler -> stage1 selfhost CLI core wasm (${STAGE_TIMEOUT_SEC}s)" >&2
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

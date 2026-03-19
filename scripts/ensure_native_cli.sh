#!/usr/bin/env bash
# Ensure the native CLI binary is up-to-date.
# Skips `moon build` when the binary is newer than all source files.
#
# Usage:
#   source scripts/ensure_native_cli.sh          # debug build
#   VIBE_CLI_RELEASE=1 source scripts/ensure_native_cli.sh  # release build
#
# After sourcing, VIBE_CLI_BIN is set to the binary path.
#
# To force rebuild: VIBE_CLI_FORCE=1

set -euo pipefail

_ENSURE_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
_ENSURE_RELEASE="${VIBE_CLI_RELEASE:-0}"
_ENSURE_FORCE="${VIBE_CLI_FORCE:-0}"
_ENSURE_WARN_LIST="${VIBE_MOON_WARN_LIST:--1-7-24-29}"

if [[ "$_ENSURE_RELEASE" == "1" ]]; then
  VIBE_CLI_BIN="$_ENSURE_ROOT_DIR/target/native/release/build/cmd/vibe/vibe.exe"
  _ENSURE_BUILD_FLAGS=(--target native --release src/cmd/vibe --warn-list "$_ENSURE_WARN_LIST")
else
  VIBE_CLI_BIN="$_ENSURE_ROOT_DIR/_build/native/debug/build/cmd/vibe/vibe.exe"
  _ENSURE_BUILD_FLAGS=(--target native src/cmd/vibe --warn-list "$_ENSURE_WARN_LIST")
fi

_ensure_needs_build() {
  if [[ "$_ENSURE_FORCE" == "1" ]]; then
    return 0
  fi
  if [[ ! -x "$VIBE_CLI_BIN" ]]; then
    return 0
  fi
  # Check if any .mbt source is newer than the binary
  local newest_src
  newest_src="$(find "$_ENSURE_ROOT_DIR/src" -name '*.mbt' -newer "$VIBE_CLI_BIN" -print -quit 2>/dev/null || true)"
  if [[ -n "$newest_src" ]]; then
    return 0
  fi
  # Check moon.mod.json
  if [[ "$_ENSURE_ROOT_DIR/moon.mod.json" -nt "$VIBE_CLI_BIN" ]]; then
    return 0
  fi
  return 1
}

if _ensure_needs_build; then
  (cd "$_ENSURE_ROOT_DIR" && moon build "${_ENSURE_BUILD_FLAGS[@]}" >/dev/null)
fi

export VIBE_CLI_BIN

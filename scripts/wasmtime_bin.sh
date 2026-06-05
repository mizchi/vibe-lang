#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_PREBUILT="$PROJECT_ROOT/.tools/wasmtime/bin/wasmtime"
LOCAL_RELEASE="$PROJECT_ROOT/deps/wasmtime/target/release/wasmtime"
LOCAL_DEBUG="$PROJECT_ROOT/deps/wasmtime/target/debug/wasmtime"

# Explicit override always wins.
if [ -n "${WASMTIME_BIN:-}" ]; then
  printf '%s\n' "$WASMTIME_BIN"
  exit 0
fi

if [ "${VIBE_USE_WASMTIME_PREBUILT:-0}" = "1" ]; then
  if [ -x "$LOCAL_PREBUILT" ]; then
    printf '%s\n' "$LOCAL_PREBUILT"
    exit 0
  fi
  echo "VIBE_USE_WASMTIME_PREBUILT=1 but local prebuilt wasmtime is not installed." >&2
  echo "Run: pkf run package-wasmtime-prebuilt && pkf run install-wasmtime-prebuilt" >&2
  exit 1
fi

if [ "${VIBE_USE_WASMTIME_SUBMODULE:-0}" = "1" ]; then
  if [ -x "$LOCAL_RELEASE" ]; then
    printf '%s\n' "$LOCAL_RELEASE"
    exit 0
  fi
  if [ -x "$LOCAL_DEBUG" ]; then
    printf '%s\n' "$LOCAL_DEBUG"
    exit 0
  fi
  echo "VIBE_USE_WASMTIME_SUBMODULE=1 but deps/wasmtime wasmtime binary is not built." >&2
  echo "Run: pkf run build-wasmtime-submodule" >&2
  exit 1
fi

if [ -x "$LOCAL_PREBUILT" ]; then
  printf '%s\n' "$LOCAL_PREBUILT"
  exit 0
fi

if command -v wasmtime >/dev/null 2>&1; then
  command -v wasmtime
  exit 0
fi

# Fallback to submodule build if available even without explicit opt-in.
if [ -x "$LOCAL_RELEASE" ]; then
  printf '%s\n' "$LOCAL_RELEASE"
  exit 0
fi
if [ -x "$LOCAL_DEBUG" ]; then
  printf '%s\n' "$LOCAL_DEBUG"
  exit 0
fi

echo "wasmtime not found (system PATH and deps/wasmtime build)." >&2
echo "Install wasmtime or run: pkf run install-wasmtime-prebuilt" >&2
exit 1

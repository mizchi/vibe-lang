#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="${WASMTIME_PREBUILT_INSTALL_DIR:-$PROJECT_ROOT/.tools/wasmtime}"

if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
  case "$1" in
    http://*|https://*)
      WASMTIME_PREBUILT_URL="$1"
      ;;
    *)
      WASMTIME_PREBUILT_ARCHIVE="$1"
      ;;
  esac
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -n "${WASMTIME_PREBUILT_BIN:-}" ]; then
  source_bin="$WASMTIME_PREBUILT_BIN"
elif [ -n "${WASMTIME_PREBUILT_URL:-}" ]; then
  archive_path="$tmp_dir/wasmtime-prebuilt.tar.xz"
  curl -fsSL --retry 5 --retry-all-errors -o "$archive_path" "$WASMTIME_PREBUILT_URL"
  tar -xJf "$archive_path" -C "$tmp_dir"
  source_bin="$(find "$tmp_dir" -type f -name wasmtime | head -n 1)"
elif [ -n "${WASMTIME_PREBUILT_ARCHIVE:-}" ]; then
  archive_path="$WASMTIME_PREBUILT_ARCHIVE"
  if [ ! -f "$archive_path" ]; then
    echo "wasmtime prebuilt archive not found: $archive_path" >&2
    exit 1
  fi
  tar -xJf "$archive_path" -C "$tmp_dir"
  source_bin="$(find "$tmp_dir" -type f -name wasmtime | head -n 1)"
else
  archive_path="$(find "$PROJECT_ROOT/_build/prebuilt" -type f -name 'wasmtime-v*.tar.xz' 2>/dev/null | sort | tail -n 1)"
  if [ -z "$archive_path" ]; then
    echo "wasmtime prebuilt archive not found." >&2
    echo "Run: pkf run package-wasmtime-prebuilt" >&2
    exit 1
  fi
  tar -xJf "$archive_path" -C "$tmp_dir"
  source_bin="$(find "$tmp_dir" -type f -name wasmtime | head -n 1)"
fi

if [ -z "${source_bin:-}" ] || [ ! -f "$source_bin" ]; then
  echo "wasmtime binary not found in prebuilt input" >&2
  exit 1
fi

install -d "$INSTALL_DIR/bin"
install -m 0755 "$source_bin" "$INSTALL_DIR/bin/wasmtime"
if [ -f "$(dirname "$source_bin")/VERSION" ]; then
  install -m 0644 "$(dirname "$source_bin")/VERSION" "$INSTALL_DIR/VERSION"
else
  "$INSTALL_DIR/bin/wasmtime" --version >"$INSTALL_DIR/VERSION"
fi

"$INSTALL_DIR/bin/wasmtime" --version
echo "installed: $INSTALL_DIR/bin/wasmtime"

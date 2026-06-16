#!/usr/bin/env bash
set -euo pipefail

WASMTIME_VERSION="${WASMTIME_VERSION:-45.0.2}"
WASMTIME_INSTALL_DIR="${WASMTIME_INSTALL_DIR:-$HOME/.wasmtime}"

case "$(uname -s)" in
  Linux)
    wasmtime_os="linux"
    ;;
  Darwin)
    wasmtime_os="macos"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    wasmtime_arch="x86_64"
    ;;
  arm64|aarch64)
    wasmtime_arch="aarch64"
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

archive_name="wasmtime-v${WASMTIME_VERSION}-${wasmtime_arch}-${wasmtime_os}.tar.xz"
download_url="https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/${archive_name}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

curl -fsSL --retry 5 --retry-all-errors -o "$tmp_dir/$archive_name" "$download_url"
tar -xJf "$tmp_dir/$archive_name" -C "$tmp_dir"
install -d "$WASMTIME_INSTALL_DIR/bin"
install -m 0755 \
  "$tmp_dir/wasmtime-v${WASMTIME_VERSION}-${wasmtime_arch}-${wasmtime_os}/wasmtime" \
  "$WASMTIME_INSTALL_DIR/bin/wasmtime"
"$WASMTIME_INSTALL_DIR/bin/wasmtime" --version

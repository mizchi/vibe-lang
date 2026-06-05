#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SUBMODULE_WASMTIME_ROOT="$PROJECT_ROOT/deps/wasmtime"
SIBLING_WASMTIME_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)/wasmtime"

if [ -n "${WASMTIME_PREBUILT_BIN:-}" ]; then
  wasmtime_bin="$WASMTIME_PREBUILT_BIN"
elif [ -x "$SUBMODULE_WASMTIME_ROOT/target/release/wasmtime" ]; then
  wasmtime_bin="$SUBMODULE_WASMTIME_ROOT/target/release/wasmtime"
elif [ -x "$SUBMODULE_WASMTIME_ROOT/target/debug/wasmtime" ]; then
  wasmtime_bin="$SUBMODULE_WASMTIME_ROOT/target/debug/wasmtime"
elif [ -x "$SIBLING_WASMTIME_ROOT/target/release/wasmtime" ]; then
  wasmtime_bin="$SIBLING_WASMTIME_ROOT/target/release/wasmtime"
elif [ -x "$SIBLING_WASMTIME_ROOT/target/debug/wasmtime" ]; then
  wasmtime_bin="$SIBLING_WASMTIME_ROOT/target/debug/wasmtime"
else
  echo "wasmtime binary not found." >&2
  echo "Set WASMTIME_PREBUILT_BIN or run: pkf run build-wasmtime-submodule" >&2
  exit 1
fi

version_line="$("$wasmtime_bin" --version)"
version="$(printf '%s\n' "$version_line" | awk '{print $2}')"
rev="$(
  printf '%s\n' "$version_line" |
    sed -n 's/.*(\([0-9a-f][0-9a-f]*\) .*/\1/p' |
    cut -c 1-8
)"
if [ -z "$rev" ]; then
  rev="unknown"
fi

case "$(uname -s)" in
  Linux)
    os="linux"
    ;;
  Darwin)
    os="macos"
    ;;
  *)
    echo "unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    arch="x86_64"
    ;;
  arm64|aarch64)
    arch="aarch64"
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

out_dir="${WASMTIME_PREBUILT_OUT_DIR:-$PROJECT_ROOT/_build/prebuilt}"
archive_base="wasmtime-v${version}-${rev}-${arch}-${os}"
archive_path="$out_dir/$archive_base.tar.xz"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

install -d "$out_dir"
install -d "$tmp_dir/$archive_base"
install -m 0755 "$wasmtime_bin" "$tmp_dir/$archive_base/wasmtime"
printf '%s\n' "$version_line" >"$tmp_dir/$archive_base/VERSION"

(cd "$tmp_dir" && tar -cJf "$archive_path" "$archive_base")

echo "packaged: $archive_path"
echo "version: $version_line"

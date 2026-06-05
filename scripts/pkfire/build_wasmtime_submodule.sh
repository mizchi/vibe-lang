#!/usr/bin/env bash
# Build submodule wasmtime CLI — extracted from justfile
# `build-wasmtime-submodule` recipe.
# Usage: scripts/pkfire/build_wasmtime_submodule.sh [profile=release|debug]
set -euo pipefail

profile="${1:-release}"

if ! git -C deps/wasmtime rev-parse --git-dir >/dev/null 2>&1; then
  git submodule update --init deps/wasmtime
fi

rust_toolchain="${WASMTIME_SUBMODULE_RUST_TOOLCHAIN:-1.93.0}"
cargo_cmd=(cargo)
if [ -n "$rust_toolchain" ]; then
  cargo_cmd+=(+"$rust_toolchain")
fi

if [ "$profile" = "release" ]; then
  "${cargo_cmd[@]}" build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli --release
else
  "${cargo_cmd[@]}" build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli
fi

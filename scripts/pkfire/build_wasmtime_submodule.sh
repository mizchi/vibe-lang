#!/usr/bin/env bash
# Build submodule wasmtime CLI — extracted from justfile
# `build-wasmtime-submodule` recipe.
# Usage: scripts/pkfire/build_wasmtime_submodule.sh [profile=release|debug]
set -euo pipefail

profile="${1:-release}"
git submodule update --init deps/wasmtime
if [ "$profile" = "release" ]; then
  cargo build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli --release
else
  cargo build --manifest-path deps/wasmtime/Cargo.toml -p wasmtime-cli
fi

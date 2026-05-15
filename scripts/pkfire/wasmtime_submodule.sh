#!/usr/bin/env bash
# Run submodule wasmtime CLI (build first if needed) — extracted from
# justfile `wasmtime-submodule` recipe.
# Usage: scripts/pkfire/wasmtime_submodule.sh [args...]
set -euo pipefail

if [ -x deps/wasmtime/target/release/wasmtime ]; then
  exec deps/wasmtime/target/release/wasmtime "$@"
elif [ -x deps/wasmtime/target/debug/wasmtime ]; then
  exec deps/wasmtime/target/debug/wasmtime "$@"
else
  echo "submodule wasmtime is not built. run: pkf run build-wasmtime-submodule" >&2
  exit 1
fi

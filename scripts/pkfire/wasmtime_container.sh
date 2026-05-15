#!/usr/bin/env bash
# Run wasmtime inside an x86_64 Linux container — extracted from
# justfile `wasmtime-x64` recipe (and `experimental_wasmtime_stack_switching`,
# `wasmtime-stack-switching` when --stack-switching is passed).
#
# Usage:
#   scripts/pkfire/wasmtime_container.sh [--stack-switching <file>] [args...]
#
#   plain: scripts/pkfire/wasmtime_container.sh run ...
#   with stack-switching: scripts/pkfire/wasmtime_container.sh --stack-switching foo.wasm
set -euo pipefail

if [ "${1:-}" = "--stack-switching" ]; then
  shift
  file="${1:?missing file arg after --stack-switching}"
  shift || true
  container run --platform linux/amd64 -v "$(pwd)":/work -v /tmp:/tmp rust:bookworm bash -c "\
    WASMTIME_INSTALL_DIR=\"\$HOME/.wasmtime\" bash /work/scripts/install_wasmtime_release.sh >/dev/null 2>&1 && \
    export PATH=\"\$HOME/.wasmtime/bin:\$PATH\" && \
    wasmtime run -W stack-switching=y -W exceptions=y -W function-references=y $* /work/$file"
else
  container run --platform linux/amd64 -v "$(pwd)":/work -v /tmp:/tmp rust:bookworm bash -c "\
    WASMTIME_INSTALL_DIR=\"\$HOME/.wasmtime\" bash /work/scripts/install_wasmtime_release.sh >/dev/null 2>&1 && \
    export PATH=\"\$HOME/.wasmtime/bin:\$PATH\" && \
    cd /work && \
    wasmtime $*"
fi

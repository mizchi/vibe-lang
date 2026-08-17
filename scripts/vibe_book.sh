#!/usr/bin/env bash
# Build The Vibe Book HTML site (lib/@vibex/book) from book/.
#
#   bash scripts/vibe_book.sh
#
# Writes _build/book/*.html. Uses the same compile-once tool cache pattern
# as scripts/vibe_md.sh. Invokes `_start` directly so main runs once.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

compiler="${VIBE_BOOK_COMPILER:-}"
if [ -z "$compiler" ]; then
  for gen in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${gen}stage2.wasm" ]; then
      compiler="${gen}stage2.wasm"
      break
    fi
  done
  if [ -z "$compiler" ]; then
    compiler="bootstrap/seed/compiler.wasm"
  fi
fi
if [ ! -s "$compiler" ]; then
  echo "vibe_book.sh: compiler wasm not found: $compiler" >&2
  exit 2
fi

workdir="${VIBE_BOOK_WORKDIR:-_build/vibe_book_tool}"
mkdir -p "$workdir" _build/book
tool_key="$(sha256sum scripts/vibe_book.vibex lib/@vibex/book/*.vibe lib/@vibex/book/index.vpkg "$compiler" | sha256sum | cut -c1-16)"
tool="$workdir/vibe_book.$tool_key.wasm"
build_log="$workdir/vibe_book.build.log"

if [ "${VIBE_BOOK_NO_TOOL_CACHE:-0}" = "1" ] || [ ! -s "$tool" ]; then
  find "$workdir" -maxdepth 1 -name 'vibe_book.*.wasm' ! -name "vibe_book.$tool_key.wasm" -delete 2>/dev/null || true
  rm -f "$tool" "$tool.diag" "$tool.funcmap"
  build_status=0
  env VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$compiler" scripts/vibe_book.vibex "$tool" main >"$build_log" 2>&1 || build_status=$?
  if [ "$build_status" -ne 0 ] || [ ! -s "$tool" ]; then
    echo "vibe_book.sh: failed to build scripts/vibe_book.vibex (compiler: $compiler, exit: $build_status)" >&2
    [ -s "$tool.diag" ] && cat "$tool.diag" >&2
    cat "$build_log" >&2
    rm -f "$tool" "$tool.diag"
    exit 2
  fi
  rm -f "$tool.diag" "$tool.funcmap"
fi

VIBE_PREOPEN_DIR="$ROOT_DIR" exec bash scripts/run_wasm_vibe_host_runner.sh --invoke _start "$tool"

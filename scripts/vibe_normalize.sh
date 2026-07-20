#!/usr/bin/env bash
# Selfhost `vibe normalize` (#594): canonicalize a vibe source file via the
# in-compiler normalize engine (lib/@vibe/compiler/normalize/index.vibe), run through
# the committed seed compiler (VIBE_NORMALIZE=1) on the Rust/node runner — no
# MoonBit host.
#
#   bash scripts/vibe_normalize.sh <file.vibe>          # rewrite in place
#   bash scripts/vibe_normalize.sh --check <file.vibe>  # exit 1 if not normalized
#   bash scripts/vibe_normalize.sh --stdout <file.vibe> # print result, no write
#
# Pipeline: parse -> module-flatten -> DCE from exported roots -> section layout
# (//# Imports / Types / Functions / Tests) rendered via the AST printer.
# Paths must live under the repo root (the wasm preopen dir).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mode="write"
case "${1:-}" in
  --check) mode="check"; shift ;;
  --stdout) mode="stdout"; shift ;;
  -*) echo "vibe_normalize.sh: unknown flag: $1" >&2; exit 2 ;;
esac

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_normalize.sh [--check|--stdout] <file.vibe>" >&2
  exit 2
fi

src="$1"
case "$src" in
  "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
  /*) echo "vibe_normalize.sh: path must be under the repo root: $src" >&2; exit 2 ;;
  *) src_rel="$src" ;;
esac
[ -f "$ROOT_DIR/$src_rel" ] || { echo "vibe_normalize.sh: not found: $src_rel" >&2; exit 2; }

seed="$ROOT_DIR/bootstrap/seed/compiler.wasm"
[ -s "$seed" ] || { echo "vibe_normalize.sh: seed compiler missing: $seed" >&2; exit 1; }

mkdir -p "$ROOT_DIR/_build/vibe_normalize"
out_rel="_build/vibe_normalize/out.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_NORMALIZE=1 \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke cli_main "$seed" "$src_rel" "$out_rel" >/dev/null

[ -f "$ROOT_DIR/$out_rel" ] || { echo "vibe_normalize.sh: produced no output" >&2; exit 1; }

case "$mode" in
  stdout) cat "$ROOT_DIR/$out_rel" ;;
  check)
    if cmp -s "$ROOT_DIR/$src_rel" "$ROOT_DIR/$out_rel"; then
      exit 0
    else
      echo "not normalized: $src_rel" >&2
      exit 1
    fi
    ;;
  write) cp "$ROOT_DIR/$out_rel" "$ROOT_DIR/$src_rel" ;;
esac

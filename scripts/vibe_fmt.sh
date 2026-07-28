#!/usr/bin/env bash
# Selfhost `vibe fmt` (#594): format vibe source via the selfhost CST-token
# formatter (lib/@vibe/compiler/fmt/format.vibe), compiled by the committed seed and
# run through the Rust/node runner — no MoonBit host.
#
#   bash scripts/vibe_fmt.sh <file.vibe>          # rewrite the file in place
#   bash scripts/vibe_fmt.sh --check <file.vibe>  # exit 1 if not already formatted
#   bash scripts/vibe_fmt.sh --stdout <file.vibe> # print formatted result, no write
#
# Paths must live under the repo root (the wasm preopen dir).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mode="write"
case "${1:-}" in
  --check) mode="check"; shift ;;
  --stdout) mode="stdout"; shift ;;
  -*) echo "vibe_fmt.sh: unknown flag: $1" >&2; exit 2 ;;
esac

if [ "$#" -lt 1 ]; then
  echo "usage: vibe_fmt.sh [--check|--stdout] <file.vibe>" >&2
  exit 2
fi

src="$1"
case "$src" in
  "$ROOT_DIR"/*) src_rel="${src#"$ROOT_DIR"/}" ;;
  /*) echo "vibe_fmt.sh: path must be under the repo root: $src" >&2; exit 2 ;;
  *) src_rel="$src" ;;
esac
[ -f "$ROOT_DIR/$src_rel" ] || { echo "vibe_fmt.sh: not found: $src_rel" >&2; exit 2; }

entry_wasm_rel="$(bash "$ROOT_DIR/scripts/ensure_vibe_fmt_entry.sh")"

out_rel="_build/vibe_fmt/out.vibe"
VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke main "$entry_wasm_rel" "$src_rel" "$out_rel" >/dev/null

[ -f "$ROOT_DIR/$out_rel" ] || { echo "vibe_fmt.sh: formatter produced no output" >&2; exit 1; }

case "$mode" in
  stdout) cat "$ROOT_DIR/$out_rel" ;;
  check)
    if cmp -s "$ROOT_DIR/$src_rel" "$ROOT_DIR/$out_rel"; then
      exit 0
    else
      echo "not formatted: $src_rel" >&2
      exit 1
    fi
    ;;
  write) cp "$ROOT_DIR/$out_rel" "$ROOT_DIR/$src_rel" ;;
esac

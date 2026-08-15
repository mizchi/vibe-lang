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

# The formatter's output path is PER PROCESS. It used to be the fixed
# `_build/vibe_fmt/out.vibe`, which two concurrent `vibe_fmt.sh` runs would
# clobber -- each then compared its OWN source against whichever process wrote
# last, so `--check` reported files as unformatted at random. Found while
# parallelizing the doctest driver (#819): `fmt-check` over 7 docs went from
# 0 failures serially to 4-7 different failures per parallel run. Nothing
# reads this path from outside, so making it unique costs nothing.
out_rel="_build/vibe_fmt/out.$$.vibe"
mkdir -p "$ROOT_DIR/_build/vibe_fmt"
trap 'rm -f "$ROOT_DIR/$out_rel"' EXIT
# The runner exits 0 whatever `main` returns, printing the return value as the
# last stdout line instead. Discarding stdout therefore discarded the entry's
# only way to say "I refused to format this" -- so a formatter that declined to
# rewrite a file looked exactly like one that had nothing to change (#1821).
entry_rc="$(VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" \
  --invoke main "$entry_wasm_rel" "$src_rel" "$out_rel" | tail -1)"
if [ "$entry_rc" != "0" ]; then
  echo "vibe_fmt.sh: formatter declined to rewrite $src_rel; the file is untouched" >&2
  exit 1
fi

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

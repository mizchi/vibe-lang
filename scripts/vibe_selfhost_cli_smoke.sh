#!/usr/bin/env bash
# Smoke test for the Stage 3 opt-in selfhost CLI seam (scripts/vibe_selfhost_cli.sh):
# compile a sample through the selfhost compiler wasm and run it, asserting 42.
# Demonstrates that compile/check route through selfhost codegen at runtime.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selfhost_cli_smoke.XXXXXX")"
# Keep the work dir under the repo root so paths are inside the wasm preopen.
WORK="$ROOT_DIR/_build/vibe_selfhost_cli_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$TMP" "$WORK"' EXIT

SRC="$WORK/sample.vibe"
OUT="$WORK/sample.wasm"
printf 'export let _start = () -> Int { 40 + 2 }\n' > "$SRC"

echo "[smoke] compile via selfhost CLI seam"
VIBE_CLI_BIN_OVERRIDE="$ROOT_DIR/scripts/vibe_selfhost_cli.sh" \
  bash "$ROOT_DIR/scripts/run_cached_vibe.sh" compile --wasm "$SRC" -o "$OUT"

if [ ! -f "$OUT" ]; then
  echo "[smoke] FAIL: no wasm produced" >&2
  exit 1
fi
magic="$(od -An -t x1 -N 4 "$OUT" | tr -d ' \n')"
if [ "$magic" != "0061736d" ]; then
  echo "[smoke] FAIL: output is not wasm (magic=$magic)" >&2
  exit 1
fi

echo "[smoke] run produced wasm"
result="$(VIBE_PREOPEN_DIR="$ROOT_DIR" bash "$ROOT_DIR/scripts/run_wasm_vibe_host_runner.sh" --invoke _start "$OUT" 2>/dev/null | tr -dc '0-9')"
if [ "$result" != "42" ]; then
  echo "[smoke] FAIL: expected 42, got '$result'" >&2
  exit 1
fi

echo "[smoke] ok: compile+run through selfhost CLI seam returned 42"

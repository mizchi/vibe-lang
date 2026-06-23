#!/usr/bin/env bash
# Smoke test for selfhost `vibe run` (scripts/vibe_run.sh): compile + execute a
# single-file and a multi-file program via the seed, asserting their results.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_run_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK" "$ROOT_DIR/_build/vibe_run"' EXIT

# single-file
printf 'let main = () -> Int {\n  let xs = [1, 2, 3, 4]\n  Array::fold(xs, 0, _ + _)\n}\n' > "$WORK/prog.vibe"
out="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/prog.vibe" main | tr -dc '0-9\n' | grep -E '.' | tail -1)"
if [ "$out" != "10" ]; then
  echo "[vibe-run-smoke] FAIL single-file: expected 10, got '$out'" >&2; exit 1
fi

# multi-file (FS import resolution)
printf 'export let dbl = (x: Int) -> Int { x * 2 }\n' > "$WORK/lib.vibe"
printf 'import ./lib.vibe { dbl }\nlet main = () -> Int { dbl(21) }\n' > "$WORK/m2.vibe"
out2="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/m2.vibe" | tr -dc '0-9\n' | grep -E '.' | tail -1)"
if [ "$out2" != "42" ]; then
  echo "[vibe-run-smoke] FAIL multi-file: expected 42, got '$out2'" >&2; exit 1
fi

echo "[vibe-run-smoke] ok (single=10, multi-file=42)"

#!/usr/bin/env bash
# Smoke test for selfhost `vibe run` (scripts/vibe_run.sh): compile + execute a
# single-file and a multi-file program via the seed, asserting their results.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_run_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK" "$ROOT_DIR/_build/vibe_run"' EXIT

# single-file executable root
printf 'fn main with Stdout {\n  let xs = [1, 2, 3, 4]\n  let total = Array::fold(xs, 0, _ + _)\n  Stdout::write_stream("\\{total}\\n")\n}\n' > "$WORK/prog.vibex"
out="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/prog.vibex" | tr -dc '0-9\n' | grep -E '.' | head -1)"
if [ "$out" != "10" ]; then
  echo "[vibe-run-smoke] FAIL single-file: expected 10, got '$out'" >&2; exit 1
fi

# multi-file (FS import resolution)
printf 'export let dbl = (x: Int) -> Int { x * 2 }\n' > "$WORK/lib.vibe"
printf 'import ./lib.vibe { dbl }\nfn main with Stdout { Stdout::write_stream("\\{dbl(21)}\\n") }\n' > "$WORK/m2.vibex"
out2="$(bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/m2.vibex" | tr -dc '0-9\n' | grep -E '.' | head -1)"
if [ "$out2" != "42" ]; then
  echo "[vibe-run-smoke] FAIL multi-file: expected 42, got '$out2'" >&2; exit 1
fi

# A library/module source is never accepted by the executable launcher.
printf 'let main = () -> Int { 0 }\n' > "$WORK/legacy.vibe"
legacy_err="$WORK/legacy.err"
if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/legacy.vibe" > /dev/null 2> "$legacy_err"; then
  echo "[vibe-run-smoke] FAIL: .vibe executable was accepted" >&2; exit 1
fi
grep -q "vibe run requires a .vibex executable root" "$legacy_err" || {
  echo "[vibe-run-smoke] FAIL: missing .vibe rejection diagnostic" >&2; exit 1
}

# The user-visible entry is fixed; arbitrary positional entries are not ABI.
entry_err="$WORK/entry.err"
if bash "$ROOT_DIR/scripts/vibe_run.sh" "$WORK/prog.vibex" alternate > /dev/null 2> "$entry_err"; then
  echo "[vibe-run-smoke] FAIL: custom .vibex entry was accepted" >&2; exit 1
fi
grep -q ".vibex entry is always main" "$entry_err" || {
  echo "[vibe-run-smoke] FAIL: missing custom-entry rejection diagnostic" >&2; exit 1
}

echo "[vibe-run-smoke] ok (single=10, multi-file=42)"

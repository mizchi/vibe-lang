#!/usr/bin/env bash
# minify_wasm.sh — converge vibe-opt over a LARGE wasm module by running one
# minify round per process (#1109-1).
#
# The in-wasm `minify_converge` allocates through the bump allocator and never
# frees, so 16 rounds over a 1.4MB module exhaust guest memory. This driver
# invokes `vibe-opt --single-round` repeatedly instead: each round is a fresh
# instance (memory resets), and we stop when a round stops shrinking, with a
# hard cap mirroring minify_converge's max_rounds.
#
# usage: bash scripts/minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c]
# env:   VIBE_OPT_WASM (default _build/vibe-opt.wasm, built on demand)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:?usage: minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c]}"
OUT="${2:?usage: minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c]}"
shift 2
KEEP_ARGS=()
if [ "${1:-}" = "--keep-exports" ]; then
  KEEP_ARGS=(--keep-exports "${2:?--keep-exports needs a comma-separated list}")
fi
MAX_ROUNDS="${VIBE_MINIFY_MAX_ROUNDS:-16}"
OPT_WASM="${VIBE_OPT_WASM:-$ROOT/_build/vibe-opt.wasm}"
RUN="bash $ROOT/scripts/run_wasm_vibe_host_runner.sh"

[ -f "$OPT_WASM" ] || bash "$ROOT/scripts/build_vibe_opt.sh" "$OPT_WASM" >/dev/null

work="$(mktemp -d -t vibe-minify-XXXXXX)"
trap 'rm -rf "$work"' EXIT
cp "$IN" "$work/cur.wasm"
prev=$(wc -c <"$work/cur.wasm")
orig="$prev"

round=1
# Round 1 applies the export filter (if any); later rounds must NOT re-filter
# (the list's names are already the only exports; re-passing is harmless but
# keeping the flag to round 1 makes the loop's convergence purely size-driven).
$RUN "$OPT_WASM" --single-round ${KEEP_ARGS[@]+"${KEEP_ARGS[@]}"} "$work/cur.wasm" "$work/next.wasm" >/dev/null
mv "$work/next.wasm" "$work/cur.wasm"
size=$(wc -c <"$work/cur.wasm")
echo "[minify-wasm] round 1: $prev -> $size"

while [ "$size" -lt "$prev" ] && [ "$round" -lt "$MAX_ROUNDS" ]; do
  prev="$size"
  round=$((round + 1))
  $RUN "$OPT_WASM" --single-round "$work/cur.wasm" "$work/next.wasm" >/dev/null
  mv "$work/next.wasm" "$work/cur.wasm"
  size=$(wc -c <"$work/cur.wasm")
  echo "[minify-wasm] round $round: $prev -> $size"
done

cp "$work/cur.wasm" "$OUT"
pct=$(( (orig - size) * 100 / orig ))
echo "[minify-wasm] done: $IN ${orig}B -> $OUT ${size}B (-${pct}%) in $round round(s)"

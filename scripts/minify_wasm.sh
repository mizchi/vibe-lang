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
# usage: bash scripts/minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c] [--per-pass]
# env:   VIBE_OPT_WASM (default _build/vibe-opt.wasm, built on demand)
#
# --per-pass: one PASS per process instead of one round per process. Needed
# for very large modules — a single full round over the 4.9MB vibec core
# exhausts the 4GB wasm address space under the bump allocator (heap_ptr
# wraps), but any single pass fits. ~17 invocations per round.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IN="${1:?usage: minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c] [--per-pass]}"
OUT="${2:?usage: minify_wasm.sh <in.wasm> <out.wasm> [--keep-exports a,b,c] [--per-pass]}"
shift 2
KEEP_ARGS=()
PER_PASS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-exports) KEEP_ARGS=(--keep-exports "${2:?--keep-exports needs a comma-separated list}"); shift 2 ;;
    --per-pass) PER_PASS=1; shift ;;
    *) echo "minify_wasm.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# minify's pipeline order (see lib/@vibe/optimizer wasm_opt.vibe `minify` and
# vibe_opt.vibex run_single_pass — "dce_auto" is the size-guarded
# dce_remove-vs-dce choice).
PASSES=(strip_custom_sections directize call_forwarding fold_table_size
  eliminate_dead_stores optimize_code_section inline_empty_calls inline_calls
  remove_dead_blocks drop_unused_tables dce_auto drop_unused_globals
  drop_unused_tags propagate_local_copies coalesce_locals remove_unused_types
  remove_empty_sections)
MAX_ROUNDS="${VIBE_MINIFY_MAX_ROUNDS:-16}"
OPT_WASM="${VIBE_OPT_WASM:-$ROOT/_build/vibe-opt.wasm}"
RUN="bash $ROOT/scripts/run_wasm_vibe_host_runner.sh"

[ -f "$OPT_WASM" ] || bash "$ROOT/scripts/build_vibe_opt.sh" "$OPT_WASM" >/dev/null

work="$(mktemp -d -t vibe-minify-XXXXXX)"
trap 'rm -rf "$work"' EXIT
cp "$IN" "$work/cur.wasm"
prev=$(wc -c <"$work/cur.wasm")
orig="$prev"

# Run one full round: whole-pipeline in one process, or (--per-pass) each
# pass in its own process. $1 = extra args for the FIRST invocation of the
# round (the export filter, round 1 only).
run_round() {
  local first_extra="$1"
  if [ "$PER_PASS" = "1" ]; then
    local extra="$first_extra"
    local p
    for p in "${PASSES[@]}"; do
      # shellcheck disable=SC2086
      $RUN "$OPT_WASM" --pass "$p" $extra "$work/cur.wasm" "$work/next.wasm" >/dev/null
      mv "$work/next.wasm" "$work/cur.wasm"
      extra=""
    done
  else
    # shellcheck disable=SC2086
    $RUN "$OPT_WASM" --single-round $first_extra "$work/cur.wasm" "$work/next.wasm" >/dev/null
    mv "$work/next.wasm" "$work/cur.wasm"
  fi
}

round=1
# Round 1 applies the export filter (if any); later rounds must NOT re-filter
# (the list's names are already the only exports; re-passing is harmless but
# keeping the flag to round 1 makes the loop's convergence purely size-driven).
run_round "${KEEP_ARGS[*]:-}"
size=$(wc -c <"$work/cur.wasm")
echo "[minify-wasm] round 1: $prev -> $size"
prev="$size"

# Each subsequent round must strictly shrink to be kept. With --per-pass a
# single pass is allowed to grow (dce_auto etc. compare whole rounds, not
# passes), so a complete round can come out equal-or-larger than what went
# in; run_round already overwrote cur.wasm by the time we can check, so back
# up before running and restore on a non-shrinking round instead of letting
# it become the final output.
while [ "$round" -lt "$MAX_ROUNDS" ]; do
  cp "$work/cur.wasm" "$work/prev_round.wasm"
  round=$((round + 1))
  run_round ""
  size=$(wc -c <"$work/cur.wasm")
  echo "[minify-wasm] round $round: $prev -> $size"
  if [ "$size" -ge "$prev" ]; then
    mv "$work/prev_round.wasm" "$work/cur.wasm"
    size="$prev"
    round=$((round - 1))
    echo "[minify-wasm] did not shrink further; keeping round $round's result"
    break
  fi
  prev="$size"
done

cp "$work/cur.wasm" "$OUT"
pct=$(( (orig - size) * 100 / orig ))
echo "[minify-wasm] done: $IN ${orig}B -> $OUT ${size}B (-${pct}%) in $round round(s)"

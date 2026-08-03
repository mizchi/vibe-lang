#!/usr/bin/env bash
# ADR-0092 exit-criterion lane: selfcompile KPI for an RC-built stage2 vs the
# bump-built baseline, as one parseable ratio line.
#
# compiler_gate.sh pins the SELF-BUILD to VIBE_RC=0 (bump) as a performance
# default; ADR-0092's exit criterion for lifting that pin is
#   wall(RC-built stage2) / wall(bump-built stage2)  <=  1.2
# on the same workload. This script builds both stage2 artifacts from the
# current tree (VIBE_RC=0 and VIBE_RC=1 self-builds), then times them.
#
#   scripts/selfcompile_kpi_rc_lane.sh [runs] [input.vibe]
#
# Output (stdout, last line):
#   [selfcompile-kpi-rc] input=<p> runs=<n> bump_wall_ms=<med> rc_wall_ms=<med>
#                        ratio=<med-of-medians> paired_ratio=<med-of-pairs>
#
# MEASUREMENT DISCIPLINE (#1262, learned the hard way -- read before changing
# this loop). Wall time is machine/load dependent, and on a shared/virtualized
# runner the drift over one invocation is LARGER than the effect being
# measured: a 7-run sample on one container spread bump over 4346..7447ms,
# a 1.7x range against a ~1.8x effect.
#
#   * The runs are INTERLEAVED (bump, rc, bump, rc, ...), never
#     all-bump-then-all-rc. The original all-then-all form put every bump run
#     in the minutes right after the two self-builds, when the machine was
#     still settling, and every rc run after it had quieted down -- it charged
#     the warm-up entirely to the bump lane and so UNDERSTATED the ratio.
#     Same tree, same artifacts, same 3 runs each: all-then-all read 1.193
#     (bump_med 8304) while interleaved read 1.820 (bump_med 5218). The 1.193
#     would have been reported as "exit criterion met".
#   * `paired_ratio` is the median of the per-ROUND rc/bump ratios. Each pair
#     is measured seconds apart, so slow drift cancels inside the pair; it is
#     the number to trust when the two lanes disagree.
#   * Compare only WITHIN one invocation. Numbers from separate invocations
#     (let alone separate machines) are not comparable in either direction.
#
# This is a tracking lane, not a CI gate. Build dirs are kept under _build/
# so repeated invocations reuse nothing stale (each call rebuilds both
# generations from the tree).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

RUNS="${1:-3}"
INPUT="${2:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"

echo "[selfcompile-kpi-rc] building bump stage2 (VIBE_RC=0) ..."
VIBE_RC=0 bash scripts/generations.sh build --out-dir _build/kpi_gen_bump >/dev/null
echo "[selfcompile-kpi-rc] building rc stage2 (VIBE_RC=1) ..."
VIBE_RC=1 bash scripts/generations.sh build --out-dir _build/kpi_gen_rc >/dev/null

one_wall() {
  bash scripts/selfcompile_kpi.sh "$1" "$INPUT" | tail -1 |
    sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p'
}

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

bump_vals=()
rc_vals=()
pair_ratios=()
i=0
while [ "$i" -lt "$RUNS" ]; do
  b=$(one_wall _build/kpi_gen_bump/stage2.wasm)
  r=$(one_wall _build/kpi_gen_rc/stage2.wasm)
  bump_vals+=("$b")
  rc_vals+=("$r")
  pair_ratios+=("$(awk -v a="$r" -v b="$b" 'BEGIN { printf "%.4f", a / b }')")
  i=$((i + 1))
done

bump_med=$(median "${bump_vals[@]}")
rc_med=$(median "${rc_vals[@]}")
ratio=$(awk -v a="$rc_med" -v b="$bump_med" 'BEGIN { printf "%.3f", a / b }')
paired=$(median "${pair_ratios[@]}")
echo "[selfcompile-kpi-rc] bump_runs=${bump_vals[*]}"
echo "[selfcompile-kpi-rc] rc_runs=${rc_vals[*]}"
echo "[selfcompile-kpi-rc] input=$INPUT runs=$RUNS bump_wall_ms=$bump_med rc_wall_ms=$rc_med ratio=$ratio paired_ratio=$paired"

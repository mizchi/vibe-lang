#!/usr/bin/env bash
# ADR-0092 exit-criterion lane: selfcompile KPI for an RC-built stage2 vs the
# bump-built baseline, as one parseable ratio line.
#
# compiler_gate.sh pins the SELF-BUILD to VIBE_RC=0 (bump) as a performance
# default; ADR-0092's exit criterion for lifting that pin is
#   wall(RC-built stage2) / wall(bump-built stage2)  <=  1.2
# on the same workload. This script builds both stage2 artifacts from the
# current tree (VIBE_RC=0 and VIBE_RC=1 self-builds), runs
# scripts/selfcompile_kpi.sh N times on each, and reports medians + ratio.
#
#   scripts/selfcompile_kpi_rc_lane.sh [runs] [input.vibe]
#
# Output (stdout, last line):
#   [selfcompile-kpi-rc] input=<p> runs=<n> bump_wall_ms=<med> rc_wall_ms=<med> ratio=<r>
#
# Wall time is machine/load dependent: this is a tracking lane, not a CI
# gate. Build dirs are kept under _build/ so repeated invocations reuse
# nothing stale (each call rebuilds both generations from the tree).
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

median_wall() {
  local stage2="$1" runs="$2" input="$3"
  local vals=()
  local i=0
  while [ "$i" -lt "$runs" ]; do
    local line
    line=$(bash scripts/selfcompile_kpi.sh "$stage2" "$input" | tail -1)
    vals+=("$(sed -n 's/.*wall_ms=\([0-9]*\).*/\1/p' <<<"$line")")
    i=$((i + 1))
  done
  printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'
}

bump_med=$(median_wall _build/kpi_gen_bump/stage2.wasm "$RUNS" "$INPUT")
rc_med=$(median_wall _build/kpi_gen_rc/stage2.wasm "$RUNS" "$INPUT")
ratio=$(awk -v a="$rc_med" -v b="$bump_med" 'BEGIN { printf "%.3f", a / b }')
echo "[selfcompile-kpi-rc] input=$INPUT runs=$RUNS bump_wall_ms=$bump_med rc_wall_ms=$rc_med ratio=$ratio"

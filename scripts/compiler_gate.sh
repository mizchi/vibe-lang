#!/usr/bin/env bash
# Moon-free selfhost-only gate (#594 Stage 5).
#
# Thin aggregator over independently runnable lanes under tests/gates/
# (#1849 / #2001). Default (no args) runs every lane in order and is the
# `pkf run test` / `full-gate` entrypoint — behaviour-equivalent to the
# former 12k-line script.
#
#   bash scripts/compiler_gate.sh                  # all lanes
#   bash scripts/compiler_gate.sh --list           # known lanes
#   COMPILER_GATE_LANE=early bash scripts/compiler_gate.sh
#   bash scripts/compiler_gate.sh early mid
#
# A lane that is not `bootstrap` resolves stage2 via VIBE_STAGE2_WASM, a
# leftover generations/ tree, or a unit-test-style build from the committed
# flat module source. That is what lets CI start the fixture lanes at t=0
# instead of serializing behind this job.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/gates/lib.sh"

usage() {
  cat <<'EOF' >&2
usage: compiler_gate.sh [--list] [lane ...]
  COMPILER_GATE_LANE=name   run one lane (ignored when lanes are passed)
  --list                    print known lanes, one per line
EOF
}

list_lanes() {
  for lane in $GATE_LANES; do
    printf '%s\n' "$lane"
  done
}

validate_lane() {
  local want="$1"
  local lane
  for lane in $GATE_LANES; do
    if [ "$lane" == "$want" ]; then
      return 0
    fi
  done
  echo "[compiler-gate] FAIL: unknown lane '$want' (expected: $GATE_LANES)" >&2
  exit 2
}

selected=()
if [ "${1:-}" = "--list" ]; then
  list_lanes
  exit 0
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -gt 0 ]; then
  selected=("$@")
elif [ -n "${COMPILER_GATE_LANE:-}" ]; then
  selected=("$COMPILER_GATE_LANE")
else
  # default: every lane, bootstrap first so later lanes reuse its stage2.
  read -r -a selected <<< "$GATE_LANES"
fi

for lane in "${selected[@]}"; do
  validate_lane "$lane"
done

for lane in "${selected[@]}"; do
  script="$(gate_lane_script "$lane")"
  if [ ! -f "$script" ]; then
    echo "[compiler-gate] FAIL: missing lane entrypoint $script" >&2
    exit 1
  fi
  echo "[compiler-gate] lane $lane"
  bash "$script"
done

echo "[compiler-gate] ok"

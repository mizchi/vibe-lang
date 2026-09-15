#!/usr/bin/env bash
# Resolve the compiler this checkout built before measuring it: a KPI that
# silently falls back to the committed seed reports numbers for a compiler that
# does not contain the change (AGENTS.md, "Which compiler answered?").
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/resolve_stage2.sh
stage2="$(resolve_stage2 incremental-kpi "${VIBE_STAGE2_WASM:-}")"
case "$stage2" in
  bootstrap/seed/*|*/bootstrap/seed/*)
    echo 'incremental-kpi: build a current stage2 first; the seed cannot measure this change' >&2
    exit 1 ;;
esac
exec node scripts/incremental_kpi.mjs "$stage2" "$@"

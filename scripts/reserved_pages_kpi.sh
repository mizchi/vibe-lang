#!/usr/bin/env bash
# Reserved-page KPI for fixed package closures (#3647): see
# scripts/reserved_pages_kpi.mjs for what is measured and gated.
#
# Measure the compiler this checkout built, or measure nothing -- the same
# rule as scripts/incremental_kpi.sh (AGENTS.md, "Which compiler answered?";
# #2836 §1). The pkfire task carries `deps { selfhostGeneration }` so the
# artifact this insists on exists; CI names its own build in VIBE_STAGE2_WASM.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/resolve_stage2.sh
stage2="$(resolve_stage2_strict reserved-pages-kpi "${VIBE_STAGE2_WASM:-}")" || exit 1
case "$stage2" in
  bootstrap/seed/*|*/bootstrap/seed/*)
    echo 'reserved-pages-kpi: build a current stage2 first; the seed cannot measure this checkout' >&2
    exit 1 ;;
esac
exec node scripts/reserved_pages_kpi.mjs "$stage2" "$@"

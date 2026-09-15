#!/usr/bin/env bash
# Measure the compiler this checkout built, or measure nothing. A KPI that
# falls back -- to the committed seed, or to whichever generation happens to be
# newest in a reused workspace -- reports numbers for a compiler that does not
# contain the change, and the number reads the same either way (AGENTS.md,
# "Which compiler answered?"; #2836 §1). The pkfire task carries
# `deps { selfhostGeneration }` so the artifact this insists on exists.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/resolve_stage2.sh
stage2="$(resolve_stage2_strict incremental-kpi "${VIBE_STAGE2_WASM:-}")" || exit 1
# Strict resolution already refuses the seed as a FALLBACK; this covers the
# remaining way to reach it, an explicit VIBE_STAGE2_WASM pointing at it.
case "$stage2" in
  bootstrap/seed/*|*/bootstrap/seed/*)
    echo 'incremental-kpi: build a current stage2 first; the seed cannot measure this change' >&2
    exit 1 ;;
esac
exec node scripts/incremental_kpi.mjs "$stage2" "$@"

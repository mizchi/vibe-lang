#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/resolve_stage2.sh
checked_stage2="$(resolve_stage2 checked-module-parity "${VIBE_STAGE2_WASM:-}")"
case "$checked_stage2" in
  bootstrap/seed/*|*/bootstrap/seed/*)
    echo 'checked-module-parity: build a current stage2 first; the seed cannot validate this change' >&2
    exit 1 ;;
esac
exec node scripts/checked_module_cache_parity.mjs "$checked_stage2" "$@"

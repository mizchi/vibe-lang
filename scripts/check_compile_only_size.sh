#!/usr/bin/env bash
# The compile-only size budget (#2506): the compile-only artifact
# (scripts/build_compile_only.sh) must stay at least the committed separation
# smaller than the full CLI stage2 built from the same source. What is
# budgeted, why the CLI is the reference and not a cap (#1109-4), and every
# provenance refusal are in scripts/compile_only_size_budget.mjs; the numbers
# and how to rebaseline are in bench/perf/compile_only_size_baseline.txt.
#
# Usage:
#   bash scripts/check_compile_only_size.sh [--artifact W] [--baseline F] [--print]
#     --artifact W  a compile-only artifact with its build receipt
#                   (<W>.receipt.json). Default: the named artifact the lanes
#                   gate builds, _build/compile_only/vibe_compile_only.names.wasm,
#                   rebuilt here when its receipt does not match this checkout
#                   and this stage2.
#     --baseline F  default bench/perf/compile_only_size_baseline.txt
#     --print       print the measurement as baseline lines instead of judging
#
# The stage2 is a MEASUREMENT input, so it is resolved strictly: the
# COMPILE_ONLY_STAGE2 / VIBE_STAGE2_WASM override, else HEAD's generation,
# else refuse (scripts/resolve_stage2.sh). Never the seed, never the newest
# generation on disk.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

ARTIFACT=""
BASELINE="$ROOT_DIR/bench/perf/compile_only_size_baseline.txt"
PRINT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --print) PRINT="--print"; shift ;;
    *) echo "compile-only-size: unknown argument: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "compile-only-size: FAIL: $*" >&2; exit 1; }

STAGE2="$(resolve_stage2_strict compile-only-size "${COMPILE_ONLY_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
STAGE2="$(cd "$(dirname "$STAGE2")" && pwd)/$(basename "$STAGE2")"

# The CLI side is held to this checkout's generated module source, so bring
# the generated files up to date first -- under the cleared adapter selectors,
# because the generator drives the seed's cli_main and an inherited
# `VIBE_CHECK_ONLY=1` would hijack it (the same reason build_compile_only.sh
# clears them).
env $(bash "$ROOT_DIR/scripts/adapter_selector_order.sh" | awk '{for (i = 1; i <= NF; i++) printf "-u %s ", $i}') \
  bash "$ROOT_DIR/scripts/ensure_generated.sh" >&2 || fail "scripts/ensure_generated.sh failed"
FINGERPRINT="$(bash "$ROOT_DIR/scripts/ensure_generated.sh" --print-fingerprint 2>/dev/null)" \
  || fail "could not compute the generated-source fingerprint"

if [ -z "$ARTIFACT" ]; then
  ARTIFACT="$ROOT_DIR/_build/compile_only/vibe_compile_only.names.wasm"
  # Reuse what the lanes gate just built only when its receipt says it is this
  # checkout's, by this stage2; otherwise build it rather than measure a stale
  # file. The probe is the same check the measurement makes below.
  if ! node scripts/compile_only_size_budget.mjs check --stage2 "$STAGE2" --artifact "$ARTIFACT" \
      --fingerprint "$FINGERPRINT" --print >/dev/null 2>&1; then
    echo "compile-only-size: building $ARTIFACT with $STAGE2" >&2
    bash scripts/build_compile_only.sh --names --out "$ARTIFACT" --compiler "$STAGE2" >&2 \
      || fail "scripts/build_compile_only.sh failed"
  fi
fi
[ -s "$ARTIFACT" ] || fail "artifact not found: $ARTIFACT"
[ -n "$PRINT" ] || [ -f "$BASELINE" ] || fail "baseline not found: $BASELINE"

node scripts/compile_only_size_budget.mjs check --stage2 "$STAGE2" --artifact "$ARTIFACT" \
  --fingerprint "$FINGERPRINT" --baseline "$BASELINE" $PRINT

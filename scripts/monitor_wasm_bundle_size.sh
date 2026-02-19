#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STRICT_PRODUCT="${VIBE_WASM_BUNDLE_MONITOR_STRICT_PRODUCT:-0}"

echo "[compiler bundle-size guard]"
"$ROOT_DIR/scripts/bench_compiler_bundle_size.sh"

echo ""
echo "[product bundle-size monitor]"
set +e
"$ROOT_DIR/scripts/bench_bundle_size.sh"
product_status=$?
set -e

if (( product_status != 0 )); then
  echo ""
  echo "wasm-bundle-monitor: product budget regression detected." >&2
  echo "  - monitor mode keeps this non-fatal by default." >&2
  echo "  - set VIBE_WASM_BUNDLE_MONITOR_STRICT_PRODUCT=1 to fail on product regressions." >&2
fi

if [[ "$STRICT_PRODUCT" == "1" && $product_status -ne 0 ]]; then
  exit "$product_status"
fi

echo ""
echo "wasm-bundle-monitor: completed."

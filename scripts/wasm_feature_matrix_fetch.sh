#!/usr/bin/env bash
# Refresh the vendored WebAssembly proposal support matrix.
#
# https://webassembly.org/features/ is a rendered view of a JSON data file
# maintained in the WebAssembly/website repo (not the HTML page itself) —
# fetch that master data directly so docs/wasm/feature-levels.md and
# scripts/wasm_feature_levels.vibex work from the real source, not a scrape.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_URL="https://raw.githubusercontent.com/WebAssembly/website/main/features.json"
OUT="$ROOT_DIR/docs/wasm/feature-matrix.json"

curl -fsSL "$SRC_URL" -o "$OUT.tmp"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "[wasm-feature-matrix-fetch] wrote $OUT ($(wc -c <"$OUT") bytes)"

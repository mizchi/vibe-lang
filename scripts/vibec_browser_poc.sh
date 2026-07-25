#!/usr/bin/env bash
# vibec browser PoC (#1107 Phase 5 / #857): build the vibec compiler-core
# component, transpile it with jco, and drive a full in-memory
# compile -> instantiate -> run round trip using only browser-available APIs
# (see scripts/vibec_poc_driver.mjs).
#
# usage: bash scripts/vibec_browser_poc.sh
# env:   VIBE_STAGE2_WASM / VIBE_VIBEC_COMPILER — compiler used for the core
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/_build/vibec"
cd "$ROOT"

bash scripts/build_vibec.sh "$OUT_DIR"

# jco is fetched on demand; pin-free npx keeps this a dev-side PoC (the
# artifact itself has no npm dependency).
npx --yes @bytecodealliance/jco transpile "$OUT_DIR/vibec.component.wasm" \
  -o "$OUT_DIR/jco" --no-wasi-shim >/dev/null

node scripts/vibec_poc_driver.mjs "$OUT_DIR/jco"

#!/usr/bin/env bash
# Generate the browser compiler from the same stage2 used by the release gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

stage2="${PLAYGROUND_STAGE2:-}"
if [ -z "$stage2" ]; then
  for generation in $(ls -td _build/selfhost/generations/*/ 2>/dev/null); do
    if [ -s "${generation}stage2.wasm" ]; then
      stage2="${generation}stage2.wasm"
      break
    fi
  done
fi
if [ -z "$stage2" ] || [ ! -s "$stage2" ]; then
  echo "playground: build a stage2 or set PLAYGROUND_STAGE2 to this checkout's stage2.wasm" >&2
  exit 2
fi

bash scripts/ensure_generated.sh
VIBE_STAGE2_WASM="$(cd "$(dirname "$stage2")" && pwd)/$(basename "$stage2")" \
  VIBE_VIBEC_NO_MINIFY=1 bash scripts/build_vibec.sh
rm -rf playground/src/generated
pnpm --dir playground exec jco transpile ../_build/vibec/vibec.component.wasm \
  -o src/generated --no-wasi-shim --bindgen-enable-wasm-exnref --quiet
node scripts/vibec_poc_driver.mjs playground/src/generated

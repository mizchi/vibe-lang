#!/usr/bin/env bash
# Build a fresh selfhost CLI compiler wasm from the current committed source,
# moon-free (seed -> stage1 -> stage2 via the Rust/node runner). The resulting
# stage2 wasm is the portable `vibe-cli.wasm` the installer ships and the runner
# AOT-compiles to a host-specific `.cwasm` (docs/release-roadmap.md テーマ1).
#
#   bash scripts/build_cli_wasm.sh [out.wasm]   # default: dist/cli/vibe-cli.wasm
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

out="${1:-$ROOT_DIR/dist/cli/vibe-cli.wasm}"
mkdir -p "$(dirname "$out")"

echo "[build-cli-wasm] building selfhost compiler (seed -> stage1 -> stage2)…" >&2
bash scripts/generations.sh build >/dev/null

gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
[ -n "$gen" ] && [ -s "${gen}stage2.wasm" ] || {
  echo "[build-cli-wasm] error: stage2 wasm not produced" >&2
  exit 1
}

cp "${gen}stage2.wasm" "$out"
echo "[build-cli-wasm] wrote $out ($(wc -c <"$out") bytes)" >&2
printf '%s\n' "$out"

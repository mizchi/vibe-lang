#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "bench-cmd-latency: legacy expr benchmark mode was removed; delegating to source-vs-wasmtime command comparison." >&2
exec "$ROOT_DIR/scripts/bench_compare.sh"

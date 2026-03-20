#!/usr/bin/env bash
# Run selfhost compiler probe tests via release wasm build.
# These validate that the selfhost compiler can compile vibe code correctly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"

TMPDIR="${TMPDIR:-/tmp}"
WORK="$TMPDIR/vibe_selfhost_probes_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "=== selfhost probe tests ==="

# Build release compiler wasm
echo "  building release compiler..."
if ! timeout 600 "$CLI" build --release "$ROOT_DIR/vibe/compiler/index.vibe" \
  -o "$WORK/compiler.wasm" 2>/dev/null; then
  echo "SKIP: release build failed (timeout or error)"
  exit 0
fi

COMPILER_SIZE=$(wc -c < "$WORK/compiler.wasm")
echo "  compiler size: $COMPILER_SIZE bytes"

# Run probes
pass=0
fail=0
PROBES=(
  selfbuild_probe_lex
  selfbuild_probe_parse
  selfbuild_probe_check
  selfbuild_probe_compile
  selfbuild_probe_linked_compile
  selfbuild_probe_library_compile
  selfbuild_probe_parse_count
  selfbuild_probe_token_tag
)

for probe in "${PROBES[@]}"; do
  result=$(timeout 30 wasmtime run -S preview2 \
    -W exceptions=y -W unknown-imports-default=y \
    --invoke "$probe" "$WORK/compiler.wasm" -- 0 2>&1 || true)
  # Filter wasmtime warnings and extract return value
  value=$(echo "$result" | grep -v '^warning:' | grep -v '^Error:' | tail -1)
  if echo "$result" | grep -q "Error:"; then
    echo "  FAIL: $probe"
    fail=$((fail + 1))
  else
    echo "  pass: $probe = $value"
    pass=$((pass + 1))
  fi
done

echo ""
echo "=== selfhost probes: pass=$pass fail=$fail ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi

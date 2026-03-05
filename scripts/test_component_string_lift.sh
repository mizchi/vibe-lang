#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo "=== Phase 2: Component string lift validation ==="

# Step 1: Compile fixture with force_cabi_realloc
echo "--- Compiling fixture with cabi_realloc export ---"
just run compile --wasm --force-cabi-realloc fixtures/http_p3_handler_string.vibe 2>/dev/null
CORE_WASM="dist/http_p3_handler_string.wasm"

# Check exports
echo "--- Core wasm exports ---"
EXPORTS=$(wasm-tools dump "$CORE_WASM" | grep 'export Export' || true)
echo "$EXPORTS"

# Validate core wasm
wasm-tools validate --features all "$CORE_WASM"
echo "PASS: core wasm validates"

# Check required exports
echo "$EXPORTS" | grep -c 'name: "handler"' >/dev/null
echo "PASS: handler export found"

echo "$EXPORTS" | grep -c 'name: "cabi_realloc"' >/dev/null
echo "PASS: cabi_realloc export found"

echo "$EXPORTS" | grep -c 'name: "memory"' >/dev/null
echo "PASS: memory export found"

echo ""
echo "=== All Phase 2 infrastructure checks passed ==="

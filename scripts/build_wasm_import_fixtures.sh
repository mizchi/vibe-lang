#!/usr/bin/env bash
# Rebuild the binaries under fixtures/wasm_import from their committed text.
#
#   bash scripts/build_wasm_import_fixtures.sh [--check]
#
#   counter.wasm            <- counter.wat                       (wat2wasm)
#   greeter.component.wasm  <- greeter_core.wat + greeter.wit    (wat2wasm,
#                              wasm-tools component embed / new)
#
# --check rebuilds into a scratch directory and fails when a committed binary
# differs, which is how scripts/test_wasm_import.sh keeps them honest.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FX="$ROOT_DIR/fixtures/wasm_import"
check=0
[ "${1:-}" = "--check" ] && check=1
for c in wat2wasm wasm-tools; do
  command -v "$c" >/dev/null 2>&1 || { echo "build_wasm_import_fixtures: $c is not installed" >&2; exit 2; }
done

out="$FX"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
[ "$check" = 1 ] && out="$work/out" && mkdir -p "$out"

wat2wasm "$FX/counter.wat" -o "$out/counter.wasm"
wat2wasm "$FX/greeter_core.wat" -o "$work/greeter_core.wasm"
wasm-tools component embed "$FX/greeter.wit" "$work/greeter_core.wasm" -o "$work/greeter_embedded.wasm"
wasm-tools component new "$work/greeter_embedded.wasm" -o "$out/greeter.component.wasm"

if [ "$check" = 1 ]; then
  # A component carries a `producers` section naming the wasm-tools version
  # that built it; compare with custom sections stripped so only the content
  # has to agree.
  for f in counter.wasm greeter.component.wasm; do
    wasm-tools strip --all "$out/$f" -o "$work/new_$f"
    wasm-tools strip --all "$FX/$f" -o "$work/old_$f"
    cmp -s "$work/new_$f" "$work/old_$f" || { echo "build_wasm_import_fixtures: fixtures/wasm_import/$f is stale; run bash scripts/build_wasm_import_fixtures.sh" >&2; exit 1; }
  done
  echo "build_wasm_import_fixtures: ok"
fi

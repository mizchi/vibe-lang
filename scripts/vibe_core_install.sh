#!/usr/bin/env bash
# Install the in-repo @vibe/core package (lib/@vibe/core, ADR-0063) into the
# workspace content-addressed store (.vibe/store/@vibe/core) and print its
# hashes. After installing, external-style consumers can write:
#
#   require @vibe/core <x.y.z> = #<package-hash>
#   import @vibe/core { sha1, type List, ... }
#
# (In-repo consumers can skip the store entirely and use a relative bare
# directory import of lib/@vibe/core.) The CLI wasm defaults to the committed
# seed; override with VIBE_CORE_CLI_WASM (e.g. a freshly built stage2).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[ -n "${VIBE_CORE_CLI_WASM:-}" ] || bash "$ROOT_DIR/scripts/ensure_seed.sh"
CLI="${VIBE_CORE_CLI_WASM:-bootstrap/seed/compiler.wasm}"

dest=".vibe/store/@vibe/core"
rm -rf "$dest"
mkdir -p "$dest"
# package files = the contract + its impl files (not tests/benches)
# #897: the contract is index.vpkg (renamed from index.vibei)
cp "lib/@vibe/core/index.vpkg" "$dest/"
for f in lib/@vibe/core/*.vibe; do
  base="$(basename "$f")"
  case "$base" in
    *_test.vibe|*_bench.vibe) ;; # tests stay in the repo
    *) cp "$f" "$dest/" ;;
  esac
done

out="$(mktemp)"
VIBE_HASH=1 VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$CLI" \
  "$dest/index.vpkg" "$out" __no_entry__ >/dev/null 2>&1 || true
if ! grep -q '^package ' "$out" 2>/dev/null; then
  echo "vibe_core_install.sh: hash computation failed (CLI: $CLI)" >&2
  cat "$out.diag" 2>/dev/null >&2 || true
  exit 1
fi
echo "installed @vibe/core -> $dest"
cat "$out"
rm -f "$out" "$out.diag"

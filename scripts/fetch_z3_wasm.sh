#!/usr/bin/env bash
# Fetch the pinned z3.wasm that lib/@vibex/z3 imports (`import ./z3.wasm`).
#
#   bash scripts/fetch_z3_wasm.sh [dest]   # default lib/@vibex/z3/z3.wasm
#
# It is `build/z3-built.wasm` of the npm package z3-solver, 38 MB, so it is
# fetched rather than committed (lib/@vibex/z3/.gitignore). Both the tarball
# and the extracted binary are checked against pinned sha256 sums; a mismatch
# is an error, never a warning, because the binding's types are read from
# this exact binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT_DIR/lib/@vibex/z3/z3.wasm}"
VERSION="5.3.3"
TGZ_SHA256="43d1515bb04fb13b5d1da7abd5877fa1358a8ba0e10bcb952d8e504d1e56cddf"
WASM_SHA256="591c5a534abf69c74d6c21813ef36c7e1b2d9b6151bf871a7be4803f542fa377"
URL="https://registry.npmjs.org/z3-solver/-/z3-solver-$VERSION.tgz"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

if [ -f "$DEST" ] && [ "$(sha256_of "$DEST")" = "$WASM_SHA256" ]; then
  echo "[fetch-z3] present and verified: $DEST"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "[fetch-z3] $URL"
curl -fsSL "$URL" -o "$work/z3.tgz"
got="$(sha256_of "$work/z3.tgz")"
[ "$got" = "$TGZ_SHA256" ] || { echo "[fetch-z3] FAIL tarball sha256 $got, want $TGZ_SHA256" >&2; exit 1; }
mkdir "$work/x"
tar -xzf "$work/z3.tgz" -C "$work/x" package/build/z3-built.wasm
got="$(sha256_of "$work/x/package/build/z3-built.wasm")"
[ "$got" = "$WASM_SHA256" ] || { echo "[fetch-z3] FAIL z3-built.wasm sha256 $got, want $WASM_SHA256" >&2; exit 1; }
mkdir -p "$(dirname "$DEST")"
cp "$work/x/package/build/z3-built.wasm" "$DEST"
echo "[fetch-z3] installed and verified: $DEST"

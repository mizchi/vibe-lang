#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
  echo "usage: $0 <tag|version>" >&2
  echo "example: $0 v0.0.1" >&2
}

raw_tag="${1:-}"
if [ -z "$raw_tag" ]; then
  usage
  exit 2
fi

if [[ "$raw_tag" == v* ]]; then
  TAG="$raw_tag"
  VERSION="${raw_tag#v}"
else
  TAG="v$raw_tag"
  VERSION="$raw_tag"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release-assets: invalid semver: $VERSION" >&2
  exit 1
fi

MODULE_VERSION="$(awk -F '"' '/^version[[:space:]]*=/ { print $2; exit }' "$PROJECT_ROOT/moon.mod")"

if [ "$MODULE_VERSION" != "$VERSION" ]; then
  echo "release-assets: moon.mod version mismatch (got=$MODULE_VERSION expected=$VERSION)" >&2
  exit 1
fi

OUT_DIR="$PROJECT_ROOT/dist/release/$TAG"
WASM_NAME="vibe-$TAG.wasm"
README_NAME="README.vibe-wasm.md"
MANIFEST_NAME="release-manifest.json"
CHECKSUM_NAME="SHA256SUMS.txt"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "[release-assets] building wasm/vibe/vibe.wasm"
(cd "$PROJECT_ROOT" && moon build --target wasm-gc --release src/lib)
mkdir -p "$PROJECT_ROOT/wasm/vibe"
cp "$PROJECT_ROOT/_build/wasm-gc/release/build/lib/lib.wasm" \
  "$PROJECT_ROOT/wasm/vibe/vibe.wasm"

echo "[release-assets] smoke testing wasm/vibe/vibe.wasm"
(cd "$PROJECT_ROOT" && bash scripts/test_wasm_vibe_wasmtime.sh wasm/vibe/vibe.wasm)

cp "$PROJECT_ROOT/wasm/vibe/vibe.wasm" "$OUT_DIR/$WASM_NAME"
cp "$PROJECT_ROOT/wasm/vibe/README.md" "$OUT_DIR/$README_NAME"

commit_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
cat > "$OUT_DIR/$MANIFEST_NAME" <<EOF
{
  "tag": "$TAG",
  "version": "$VERSION",
  "commit": "$commit_sha",
  "artifacts": [
    "$WASM_NAME",
    "$README_NAME"
  ]
}
EOF

(
  cd "$OUT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$WASM_NAME" "$README_NAME" "$MANIFEST_NAME" > "$CHECKSUM_NAME"
  else
    shasum -a 256 "$WASM_NAME" "$README_NAME" "$MANIFEST_NAME" > "$CHECKSUM_NAME"
  fi
)

echo "[release-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$README_NAME" \
  "$OUT_DIR/$MANIFEST_NAME" \
  "$OUT_DIR/$CHECKSUM_NAME"

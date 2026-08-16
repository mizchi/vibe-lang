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

# Selfhost-only (#594): the toolchain version lives in the launcher
# (runtime/vibe, VIBE_VERSION) — moon.mod / the MoonBit host are retired.
LAUNCHER_VERSION="$(sed -n 's/^VIBE_VERSION="\([^"]*\)".*$/\1/p' "$PROJECT_ROOT/runtime/vibe" | head -1)"

if [ "$LAUNCHER_VERSION" != "$VERSION" ]; then
  echo "release-assets: runtime/vibe VIBE_VERSION mismatch (got=$LAUNCHER_VERSION expected=$VERSION)" >&2
  exit 1
fi

OUT_DIR="$PROJECT_ROOT/dist/release/$TAG"
MANIFEST_NAME="release-manifest.json"
CHECKSUM_NAME="SHA256SUMS.txt"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

bash "$SCRIPT_DIR/build_compiler_seed_assets.sh" "$TAG" "$OUT_DIR"

WASM_NAME="vibe-compiler-$TAG.wasm"
MODSRC_NAME="vibe-compiler-module-source-$TAG.vibe"
SEED_JSON_NAME="vibe-compiler-seed-$TAG.json"
compiler_fragment="$OUT_DIR/.compiler-manifest-fragment.json"
[ -f "$compiler_fragment" ] || {
  echo "release-assets: compiler manifest fragment not produced: $compiler_fragment" >&2; exit 1; }

commit_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
node - "$compiler_fragment" "$OUT_DIR/$MANIFEST_NAME" "$TAG" "$VERSION" "$commit_sha" \
  "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" <<'NODE'
const fs = require("node:fs");
const [fragmentPath, outPath, tag, version, commit, wasmName, modsrcName, seedJsonName] =
  process.argv.slice(2);
const compiler = JSON.parse(fs.readFileSync(fragmentPath, "utf8"));
const manifest = {
  tag,
  version,
  commit,
  artifacts: [wasmName, modsrcName, seedJsonName],
  compiler,
};
fs.writeFileSync(outPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
rm -f "$compiler_fragment"

(
  cd "$OUT_DIR"
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  else
    shasum -a 256 "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  fi
)

echo "[release-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$MODSRC_NAME" \
  "$OUT_DIR/$SEED_JSON_NAME" \
  "$OUT_DIR/$MANIFEST_NAME" \
  "$OUT_DIR/$CHECKSUM_NAME"

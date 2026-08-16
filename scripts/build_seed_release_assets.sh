#!/usr/bin/env bash
set -euo pipefail

# Builds release assets for a bootstrap-bump "seed" release: just the
# compiler-bootstrap artifact trio (see build_compiler_seed_assets.sh),
# published under a `seed/<name>` tag distinct from product `v*` releases.
# No semver/launcher-version gate — bootstrap bumps aren't tied to a
# product version. Triggered by .github/workflows/seed-release.yml on
# `seed/*` tag push. See docs/bootstrap.md.
#
# Usage: build_seed_release_assets.sh <tag>
#   <tag> is the full tag name including the `seed/` prefix, e.g.
#   `seed/map-from-pairs-2026-07-17`.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

usage() {
  echo "usage: $0 <seed/tag-name>" >&2
  echo "example: $0 seed/map-from-pairs-2026-07-17" >&2
}

TAG="${1:-}"
if [ -z "$TAG" ]; then
  usage
  exit 2
fi

case "$TAG" in
  seed/*) : ;;
  *)
    echo "build-seed-release-assets: tag must start with 'seed/' (got: $TAG)" >&2
    exit 1
    ;;
esac

# Asset filenames embed only the part after `seed/` — the prefix is a tag
# namespacing device, not part of the artifact's identity.
ASSET_TAG="${TAG#seed/}"

OUT_DIR="$PROJECT_ROOT/dist/release/$TAG"
MANIFEST_NAME="release-manifest.json"
CHECKSUM_NAME="SHA256SUMS.txt"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

bash "$SCRIPT_DIR/build_compiler_seed_assets.sh" "$ASSET_TAG" "$OUT_DIR"

WASM_NAME="vibe-compiler-$ASSET_TAG.wasm"
MODSRC_NAME="vibe-compiler-module-source-$ASSET_TAG.vibe"
SEED_JSON_NAME="vibe-compiler-seed-$ASSET_TAG.json"
compiler_fragment="$OUT_DIR/.compiler-manifest-fragment.json"
[ -f "$compiler_fragment" ] || {
  echo "build-seed-release-assets: compiler manifest fragment not produced: $compiler_fragment" >&2; exit 1; }

commit_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
node - "$compiler_fragment" "$OUT_DIR/$MANIFEST_NAME" "$TAG" "$commit_sha" \
  "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" <<'NODE'
const fs = require("node:fs");
const [fragmentPath, outPath, tag, commit, wasmName, modsrcName, seedJsonName] =
  process.argv.slice(2);
const compiler = JSON.parse(fs.readFileSync(fragmentPath, "utf8"));
const manifest = {
  tag,
  kind: "bootstrap-seed",
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

echo "[seed-release-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$MODSRC_NAME" \
  "$OUT_DIR/$SEED_JSON_NAME" \
  "$OUT_DIR/$MANIFEST_NAME" \
  "$OUT_DIR/$CHECKSUM_NAME"

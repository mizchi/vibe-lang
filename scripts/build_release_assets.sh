#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "release-assets: sha256sum or shasum is required" >&2
    exit 1
  fi
}

json_string_field() {
  # naive extractor: first "<field>": "<value>" occurrence in file $1
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

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

echo "[release-assets] building clients/wasm/vibe.wasm"
(cd "$PROJECT_ROOT" && moon build --target wasm-gc --release src/lib)
mkdir -p "$PROJECT_ROOT/clients/wasm"
cp "$PROJECT_ROOT/_build/wasm-gc/release/build/lib/lib.wasm" \
  "$PROJECT_ROOT/clients/wasm/vibe.wasm"

echo "[release-assets] smoke testing clients/wasm/vibe.wasm"
(cd "$PROJECT_ROOT" && bash scripts/test_wasm_vibe_wasmtime.sh clients/wasm/vibe.wasm)

cp "$PROJECT_ROOT/clients/wasm/vibe.wasm" "$OUT_DIR/$WASM_NAME"
cp "$PROJECT_ROOT/clients/wasm/README.md" "$OUT_DIR/$README_NAME"

# --- selfhost compiler artifacts ---------------------------------------
# Unlike vibe-<tag>.wasm (the MoonBit-host lib, which needs moonbit fs
# host imports), these run the *selfhost* compiler and let a consumer
# bootstrap the stage0 -> stage1 -> stage2 build WITHOUT building the
# MoonBit host from the mooncakes registry. See
# scripts/fetch_compiler.sh and docs/bootstrap.md.
#   - vibe-selfhost-<tag>.wasm           : stage0 seed compiler wasm
#                                          (instantiates under stock
#                                           wasmtime, runs under moonrun)
#   - vibe-selfhost-module-source-<tag>.vibe : prebuilt flat module
#                                          source (emit-module-source
#                                          output for the seed entry),
#                                          so the flatten step needs no
#                                          host vibe.exe
#   - vibe-selfhost-seed-<tag>.json      : seed provenance manifest
SELFHOST_WASM_NAME="vibe-selfhost-$TAG.wasm"
SELFHOST_MODSRC_NAME="vibe-selfhost-module-source-$TAG.vibe"
SELFHOST_SEED_JSON_NAME="vibe-selfhost-seed-$TAG.json"

seed_src="$PROJECT_ROOT/bootstrap/seed/selfhost_compiler.wasm"
seed_json="$PROJECT_ROOT/bootstrap/seed.json"
[ -f "$seed_src" ] || { echo "release-assets: selfhost seed wasm missing: $seed_src" >&2; exit 1; }
[ -f "$seed_json" ] || { echo "release-assets: selfhost seed.json missing: $seed_json" >&2; exit 1; }

# Guard: the committed seed wasm must match its pinned manifest sha256.
pinned_seed_sha="$(json_string_field "$seed_json" sha256)"
actual_seed_sha="$(sha256_file "$seed_src")"
if [ -n "$pinned_seed_sha" ] && [ "$pinned_seed_sha" != "$actual_seed_sha" ]; then
  echo "release-assets: selfhost seed sha256 mismatch (manifest=$pinned_seed_sha actual=$actual_seed_sha)" >&2
  exit 1
fi
seed_source_commit="$(json_string_field "$seed_json" source_commit)"
seed_entry="$(json_string_field "$seed_json" entry)"
seed_entry_name="$(json_string_field "$seed_json" entry_name)"

echo "[release-assets] generating prebuilt flat selfhost module source"
sh_tmp="$(mktemp -d)"
if ! VIBE_BUNDLE_OUT="$sh_tmp/selfhost_sources_bundle.vibe" \
  VIBE_ADAPTER_BUNDLE_OUT="$sh_tmp/selfhost_cli_adapter_bundle.vibe" \
  VIBE_RUNTIME_ENTRY_BUNDLE_OUT="$sh_tmp/selfbuild_runtime_entry_bundle.vibe" \
  VIBE_ADAPTER_MODULE_SOURCE_OUT="$OUT_DIR/$SELFHOST_MODSRC_NAME" \
  bash "$PROJECT_ROOT/scripts/generate_bundle.sh" >"$sh_tmp/gen.log" 2>&1; then
  cat "$sh_tmp/gen.log" >&2
  echo "release-assets: selfhost module source generation failed" >&2
  exit 1
fi
[ -s "$OUT_DIR/$SELFHOST_MODSRC_NAME" ] || {
  echo "release-assets: selfhost module source not produced" >&2; exit 1; }

cp "$seed_src" "$OUT_DIR/$SELFHOST_WASM_NAME"
cp "$seed_json" "$OUT_DIR/$SELFHOST_SEED_JSON_NAME"

selfhost_wasm_sha="$(sha256_file "$OUT_DIR/$SELFHOST_WASM_NAME")"
selfhost_modsrc_sha="$(sha256_file "$OUT_DIR/$SELFHOST_MODSRC_NAME")"

commit_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || true)"
cat > "$OUT_DIR/$MANIFEST_NAME" <<EOF
{
  "tag": "$TAG",
  "version": "$VERSION",
  "commit": "$commit_sha",
  "artifacts": [
    "$WASM_NAME",
    "$README_NAME",
    "$SELFHOST_WASM_NAME",
    "$SELFHOST_MODSRC_NAME",
    "$SELFHOST_SEED_JSON_NAME"
  ],
  "selfhost": {
    "compiler_wasm": "$SELFHOST_WASM_NAME",
    "compiler_wasm_sha256": "$selfhost_wasm_sha",
    "module_source": "$SELFHOST_MODSRC_NAME",
    "module_source_sha256": "$selfhost_modsrc_sha",
    "seed_manifest": "$SELFHOST_SEED_JSON_NAME",
    "source_commit": "$seed_source_commit",
    "entry": "$seed_entry",
    "entry_name": "$seed_entry_name",
    "runtime": {
      "runner": "moonrun",
      "wasmtime_flags": "unknown-imports-default=y exceptions=y"
    }
  }
}
EOF

(
  cd "$OUT_DIR"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$WASM_NAME" "$README_NAME" "$SELFHOST_WASM_NAME" \
      "$SELFHOST_MODSRC_NAME" "$SELFHOST_SEED_JSON_NAME" "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  else
    shasum -a 256 "$WASM_NAME" "$README_NAME" "$SELFHOST_WASM_NAME" \
      "$SELFHOST_MODSRC_NAME" "$SELFHOST_SEED_JSON_NAME" "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  fi
)

echo "[release-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$README_NAME" \
  "$OUT_DIR/$SELFHOST_WASM_NAME" \
  "$OUT_DIR/$SELFHOST_MODSRC_NAME" \
  "$OUT_DIR/$SELFHOST_SEED_JSON_NAME" \
  "$OUT_DIR/$MANIFEST_NAME" \
  "$OUT_DIR/$CHECKSUM_NAME"

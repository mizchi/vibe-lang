#!/usr/bin/env bash
set -euo pipefail

# Builds the portable compiler-bootstrap artifact trio for a given release
# tag: the pinned seed compiler wasm, a prebuilt flat module source, and a
# seed provenance manifest. This lets a consumer bootstrap the stage0 ->
# stage1 -> stage2 build with no MoonBit toolchain. See
# scripts/fetch_compiler.sh and docs/internal/operations/bootstrap.md.
#
# Shared by scripts/build_release_assets.sh (product `v*` releases) and
# scripts/build_seed_release_assets.sh (bootstrap-bump `seed/*` releases).
#
# Usage: build_compiler_seed_assets.sh <tag> <out-dir>
#
# Produces (in <out-dir>):
#   vibe-compiler-<tag>.wasm             stage0 seed compiler wasm
#   vibe-compiler-module-source-<tag>.vibe   prebuilt flat module source
#   vibe-compiler-seed-<tag>.json         seed provenance manifest (copy of
#                                          bootstrap/seed.json)
#   .compiler-manifest-fragment.json      the "compiler" sub-object the
#                                          caller should splice into its own
#                                          top-level release manifest
#                                          (not itself a shipped asset)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

sha256_file() {
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif shasum -a 256 </dev/null >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "build-compiler-seed-assets: sha256sum or shasum is required" >&2
    exit 1
  fi
}

json_string_field() {
  # naive extractor: first "<field>": "<value>" occurrence in file $1
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" | head -1 \
    | sed -E "s/.*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

TAG="${1:-}"
OUT_DIR="${2:-}"
if [ -z "$TAG" ] || [ -z "$OUT_DIR" ]; then
  echo "usage: $0 <tag> <out-dir>" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

WASM_NAME="vibe-compiler-$TAG.wasm"
MODSRC_NAME="vibe-compiler-module-source-$TAG.vibe"
SEED_JSON_NAME="vibe-compiler-seed-$TAG.json"

seed_src="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
seed_json="$PROJECT_ROOT/bootstrap/seed.json"
[ -f "$seed_src" ] || { echo "build-compiler-seed-assets: seed wasm missing: $seed_src" >&2; exit 1; }
[ -f "$seed_json" ] || { echo "build-compiler-seed-assets: seed.json missing: $seed_json" >&2; exit 1; }

# Guard: the seed wasm on disk must match its pinned manifest sha256.
pinned_seed_sha="$(json_string_field "$seed_json" sha256)"
actual_seed_sha="$(sha256_file "$seed_src")"
if [ -n "$pinned_seed_sha" ] && [ "$pinned_seed_sha" != "$actual_seed_sha" ]; then
  echo "build-compiler-seed-assets: seed sha256 mismatch (manifest=$pinned_seed_sha actual=$actual_seed_sha)" >&2
  exit 1
fi
# Guard: the manifest must NAME the seed being published. `seed.name` is not
# derived from anything here -- it is whatever bootstrap/seed.json holds, and
# `generations.sh adopt` only rewrites it when given an explicit `--name`.
# Measured on seed/array-capacity-2026-09-20: dispatching seed-release with a
# `source_ref` that predates the bump commit made the Adopt step restore THAT
# commit's manifest, whose `name` still said the PREVIOUS seed. The wasm was
# correct and verified, but the published `vibe-compiler-seed-*.json` asset
# went out reading `name: bytes-capacity-2026-09-15` under
# `tag: seed/array-capacity-2026-09-20` -- a manifest disagreeing with its own
# tag, on a published artifact. Nothing in-tree reads that field, which is
# exactly why nothing caught it. The tag is the identity the assets are named
# after ($TAG is already the `seed/` prefix stripped), so require the manifest
# to agree with it rather than trusting whichever ref was dispatched.
seed_name="$(json_string_field "$seed_json" name)"
seed_tag="$(json_string_field "$seed_json" tag)"
if [ "$seed_name" != "$TAG" ]; then
  echo "build-compiler-seed-assets: seed.json names a different seed than the tag being published (seed.name=$seed_name, publishing=$TAG)" >&2
  echo "build-compiler-seed-assets: re-run \`generations.sh adopt\` with --name $TAG, or dispatch seed-release with a source_ref whose bootstrap/seed.json already names it" >&2
  exit 1
fi
if [ "$seed_tag" != "seed/$TAG" ]; then
  echo "build-compiler-seed-assets: seed.json tags a different release than the one being published (seed.tag=$seed_tag, publishing=seed/$TAG)" >&2
  echo "build-compiler-seed-assets: re-run \`generations.sh adopt\` with --tag seed/$TAG" >&2
  exit 1
fi

seed_source_commit="$(json_string_field "$seed_json" source_commit)"
seed_entry="$(json_string_field "$seed_json" entry)"
seed_entry_name="$(json_string_field "$seed_json" entry_name)"

echo "[build-compiler-seed-assets] generating prebuilt flat compiler module source"
gen_tmp="$(mktemp -d)"
if ! VIBE_BUNDLE_OUT="$gen_tmp/compiler_sources_bundle.vibe" \
  VIBE_ADAPTER_BUNDLE_OUT="$gen_tmp/cli_adapter_bundle.vibe" \
  VIBE_RUNTIME_ENTRY_BUNDLE_OUT="$gen_tmp/selfbuild_runtime_entry_bundle.vibe" \
  VIBE_ADAPTER_MODULE_SOURCE_OUT="$OUT_DIR/$MODSRC_NAME" \
  bash "$PROJECT_ROOT/scripts/generate_bundle.sh" >"$gen_tmp/gen.log" 2>&1; then
  cat "$gen_tmp/gen.log" >&2
  echo "build-compiler-seed-assets: compiler module source generation failed" >&2
  exit 1
fi
[ -s "$OUT_DIR/$MODSRC_NAME" ] || {
  echo "build-compiler-seed-assets: compiler module source not produced" >&2; exit 1; }

cp "$seed_src" "$OUT_DIR/$WASM_NAME"
cp "$seed_json" "$OUT_DIR/$SEED_JSON_NAME"

wasm_sha="$(sha256_file "$OUT_DIR/$WASM_NAME")"
modsrc_sha="$(sha256_file "$OUT_DIR/$MODSRC_NAME")"

cat > "$OUT_DIR/.compiler-manifest-fragment.json" <<EOF
{
  "compiler_wasm": "$WASM_NAME",
  "compiler_wasm_sha256": "$wasm_sha",
  "module_source": "$MODSRC_NAME",
  "module_source_sha256": "$modsrc_sha",
  "seed_manifest": "$SEED_JSON_NAME",
  "source_commit": "$seed_source_commit",
  "entry": "$seed_entry",
  "entry_name": "$seed_entry_name",
  "runtime": {
    "runner": "node",
    "wasmtime_flags": "unknown-imports-default=y exceptions=y"
  }
}
EOF

echo "[build-compiler-seed-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$MODSRC_NAME" \
  "$OUT_DIR/$SEED_JSON_NAME"

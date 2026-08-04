#!/usr/bin/env bash
set -euo pipefail

# Fetch the compiler-bootstrap artifacts published as GitHub release assets
# and verify them by sha256. This lets a constrained environment bootstrap
# the stage0 -> stage1 -> stage2 build WITHOUT building the MoonBit host
# compiler from the mooncakes registry, and is also how CI/local dev
# refreshes the local `bootstrap/seed/compiler.wasm` cache now that it's
# no longer git-tracked (see docs/bootstrap.md).
#
# Published by scripts/build_release_assets.sh (release.yml, `v*` product
# tags) or scripts/build_seed_release_assets.sh (seed-release.yml,
# `seed/*` bootstrap-bump tags):
#   - vibe-compiler-<tag>.wasm                : stage0 seed compiler wasm
#   - vibe-compiler-module-source-<tag>.vibe  : prebuilt flat module source
#   - vibe-compiler-seed-<tag>.json           : seed provenance manifest
#   - release-manifest.json / SHA256SUMS.txt  : integrity metadata
#
# Usage:
#   scripts/fetch_compiler.sh <tag> [options]
#
# Options:
#   --out-dir DIR        Place artifacts here
#                        (default: _build/selfhost/release/<tag>)
#   --adopt-seed         Also copy the compiler wasm to the in-repo seed
#                        path (bootstrap/seed/compiler.wasm)
#                        after verifying it matches bootstrap/seed.json
#   --no-module-source   Skip the prebuilt flat module source
#   --base-url URL       Override the release download base URL
#                        (default: https://github.com/mizchi/vibe-lang/releases/download/<tag>)
#   --from-dir DIR       Read assets from a local staged directory instead
#                        of downloading (for testing / air-gapped mirrors)
#   --print-env          Print shell exports wiring the prebuilt module
#                        source into scripts/generations.sh
#
# After a successful fetch with --print-env, the generation can run with
# no MoonBit host build:
#   eval "$(scripts/fetch_compiler.sh <tag> --print-env)"
#   bash scripts/generations.sh build

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"

die() { echo "fetch-compiler: $*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

TAG=""
OUT_DIR=""
ADOPT_SEED=0
WANT_MODULE_SOURCE=1
BASE_URL=""
FROM_DIR=""
PRINT_ENV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --adopt-seed) ADOPT_SEED=1; shift ;;
    --no-module-source) WANT_MODULE_SOURCE=0; shift ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --from-dir) FROM_DIR="$2"; shift 2 ;;
    --print-env) PRINT_ENV=1; shift ;;
    -h|--help) sed -n '3,46p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [ -z "$TAG" ]; then TAG="$1"; else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[ -n "$TAG" ] || die "missing <tag> (e.g. v0.0.1 or seed/map-from-pairs-2026-07-17)"
# Bare version numbers (no scheme prefix) are product releases and get a
# `v` prepended for convenience; `v*` and `seed/*` tags are passed through
# as-is (a `seed/` tag would otherwise be mangled into `vseed/...`).
case "$TAG" in v*|seed/*) : ;; *) TAG="v$TAG" ;; esac

[ -n "$OUT_DIR" ] || OUT_DIR="$PROJECT_ROOT/_build/release/$TAG"
[ -n "$BASE_URL" ] || BASE_URL="https://github.com/mizchi/vibe-lang/releases/download/$TAG"
mkdir -p "$OUT_DIR"

# Fetch one asset into $OUT_DIR (download or local copy).
fetch_asset() {
  local name="$1"
  local dest="$OUT_DIR/$name"
  if [ -n "$FROM_DIR" ]; then
    [ -f "$FROM_DIR/$name" ] || die "asset not found in --from-dir: $FROM_DIR/$name"
    cp "$FROM_DIR/$name" "$dest"
  else
    local url="$BASE_URL/$name"
    echo "[fetch] $url" >&2
    local attempt=0 delay=2
    until curl -fsSL --max-time 120 -o "$dest" "$url"; do
      attempt=$((attempt + 1))
      [ "$attempt" -ge 4 ] && die "download failed after retries: $url"
      sleep "$delay"; delay=$((delay * 2))
    done
  fi
  printf '%s\n' "$dest"
}

manifest="$(fetch_asset release-manifest.json)"

# Parse the compiler block with python3 (present in CI and dev shells).
read_manifest() {
  python3 - "$manifest" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
node = data.get("compiler") or {}
cur = node
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = ""
        break
print(cur if isinstance(cur, str) else json.dumps(cur))
PY
}

compiler_wasm_name="$(read_manifest compiler_wasm)"
compiler_wasm_sha="$(read_manifest compiler_wasm_sha256)"
module_source_name="$(read_manifest module_source)"
module_source_sha="$(read_manifest module_source_sha256)"
seed_manifest_name="$(read_manifest seed_manifest)"
source_commit="$(read_manifest source_commit)"

[ -n "$compiler_wasm_name" ] || die "release $TAG has no compiler assets in release-manifest.json. \
The release must be built with scripts/build_release_assets.sh or scripts/build_seed_release_assets.sh."

verify_sha() {
  local file="$1" want="$2"
  [ -n "$want" ] || { echo "[fetch] (no pinned sha for $(basename "$file"), skipping verify)" >&2; return 0; }
  local got; got="$(sha256_file "$file")"
  [ "$got" = "$want" ] || die "sha256 mismatch for $(basename "$file"): got=$got want=$want"
  echo "[fetch] verified $(basename "$file") sha256=$got" >&2
}

compiler_wasm="$(fetch_asset "$compiler_wasm_name")"
verify_sha "$compiler_wasm" "$compiler_wasm_sha"

module_source=""
if [ "$WANT_MODULE_SOURCE" = "1" ] && [ -n "$module_source_name" ]; then
  module_source="$(fetch_asset "$module_source_name")"
  verify_sha "$module_source" "$module_source_sha"
fi

if [ -n "$seed_manifest_name" ]; then
  fetch_asset "$seed_manifest_name" >/dev/null || true
fi

if [ "$ADOPT_SEED" = "1" ]; then
  seed_json="$PROJECT_ROOT/bootstrap/seed.json"
  seed_path="$PROJECT_ROOT/bootstrap/seed/compiler.wasm"
  if [ -f "$seed_json" ]; then
    pinned="$(grep -o '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "$seed_json" | head -1 \
      | sed -E 's/.*"([0-9a-f]+)".*/\1/')"
    got="$(sha256_file "$compiler_wasm")"
    [ -z "$pinned" ] || [ "$pinned" = "$got" ] || \
      die "--adopt-seed refused: fetched wasm sha256=$got does not match bootstrap/seed.json pinned=$pinned (tag/source mismatch)"
  fi
  mkdir -p "$(dirname "$seed_path")"
  cp "$compiler_wasm" "$seed_path"
  echo "[fetch] adopted seed -> $seed_path" >&2
fi

echo "[fetch] compiler bootstrap artifacts ready in $OUT_DIR (source_commit=$source_commit)" >&2

if [ "$PRINT_ENV" = "1" ]; then
  if [ -n "$module_source" ]; then
    printf 'export VIBE_PREBUILT_MODULE_SOURCE=%q\n' "$module_source"
    printf 'export VIBE_PREBUILT_MODULE_SOURCE_SHA256=%q\n' "$module_source_sha"
  else
    echo "# (no module source fetched; flatten will regenerate it through the seed compiler)" >&2
  fi
fi

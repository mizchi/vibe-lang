#!/usr/bin/env bash
set -euo pipefail

# Ensures the seed compiler wasm pinned by bootstrap/seed.json (or a
# --manifest override) is present and sha256-correct on disk
# (bootstrap/seed/compiler.wasm is a local build cache, gitignored — not
# committed to the repo). If it's missing or doesn't match the pinned
# sha256, fetches it from its GitHub Release (the manifest's `seed.tag`)
# via scripts/fetch_compiler.sh, then copies it to the manifest's own
# `seed.artifact.path` itself — NOT via fetch_compiler.sh's --adopt-seed,
# which always targets the project-default bootstrap/seed.json /
# bootstrap/seed/compiler.wasm regardless of --manifest, so it can't be
# used correctly when a custom manifest points elsewhere (e.g.
# scripts/generations.sh build --manifest <alternate>).
#
# Fails fast (does not silently skip or fall back to an unpinned/stale
# artifact) if the fetch is unsuccessful — see docs/bootstrap.md's CI
# offline-fallback policy. CI callers should put an actions/cache step
# keyed on the seed sha256 ahead of this so a warm runner never needs
# the network at all.
#
# Usage: scripts/ensure_seed.sh [--manifest PATH]
# Exits 0 (silently, after printing a one-line "already present" note)
# if the on-disk artifact already matches; otherwise fetches then
# re-verifies.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="${VIBE_PROJECT_ROOT:-$(dirname "$SCRIPT_DIR")}"

die() { echo "ensure-seed: $*" >&2; exit 1; }

sha256_file() {
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif shasum -a 256 </dev/null >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required"
  fi
}

MANIFEST="$PROJECT_ROOT/bootstrap/seed.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    -h|--help) sed -n '3,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -f "$MANIFEST" ] || die "seed manifest not found: $MANIFEST"

read_manifest() {
  node - "$MANIFEST" "$1" <<'NODE'
const fs = require("node:fs");
const [path, key] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(path, "utf8"));
let cur = data;
for (const part of key.split(".")) {
  if (cur == null || typeof cur !== "object" || !(part in cur)) {
    process.exit(2);
  }
  cur = cur[part];
}
process.stdout.write(String(cur));
NODE
}

SEED_TAG="$(read_manifest seed.tag)"
SEED_ARTIFACT_REL="$(read_manifest seed.artifact.path)"
SEED_ARTIFACT_SHA="$(read_manifest seed.artifact.sha256)"

case "$SEED_ARTIFACT_REL" in
  /*) SEED_ARTIFACT_PATH="$SEED_ARTIFACT_REL" ;;
  *) SEED_ARTIFACT_PATH="$PROJECT_ROOT/$SEED_ARTIFACT_REL" ;;
esac

if [ -f "$SEED_ARTIFACT_PATH" ]; then
  actual="$(sha256_file "$SEED_ARTIFACT_PATH")"
  if [ "$actual" = "$SEED_ARTIFACT_SHA" ]; then
    echo "[ensure-seed] already present and verified: $SEED_ARTIFACT_REL (sha256=$actual)" >&2
    exit 0
  fi
  echo "[ensure-seed] on-disk artifact sha256 mismatch (have=$actual want=$SEED_ARTIFACT_SHA), refetching" >&2
else
  echo "[ensure-seed] missing: $SEED_ARTIFACT_REL, fetching from release tag $SEED_TAG" >&2
fi

[ -n "$SEED_TAG" ] || die "$MANIFEST has no seed.tag to fetch from"

fetch_out="$(mktemp -d)"
trap 'rm -rf "$fetch_out"' EXIT
bash "$SCRIPT_DIR/fetch_compiler.sh" "$SEED_TAG" --out-dir "$fetch_out" --no-module-source

fetched_wasm="$(find "$fetch_out" -maxdepth 1 -name '*.wasm' | head -1)"
[ -n "$fetched_wasm" ] || die "fetch_compiler.sh did not produce a .wasm asset for tag $SEED_TAG"
mkdir -p "$(dirname "$SEED_ARTIFACT_PATH")"
cp "$fetched_wasm" "$SEED_ARTIFACT_PATH"

actual="$(sha256_file "$SEED_ARTIFACT_PATH")"
[ "$actual" = "$SEED_ARTIFACT_SHA" ] || \
  die "fetched artifact sha256 still doesn't match after fetch: got=$actual want=$SEED_ARTIFACT_SHA"
echo "[ensure-seed] fetched and verified: $SEED_ARTIFACT_REL (sha256=$actual)" >&2

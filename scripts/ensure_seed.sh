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
# If the release does not exist yet (HTTP 404 on its manifest asset: a
# bootstrap bump PR before its `seed-release` run has published the tag),
# the pinned seed is REBUILT instead of fetched: the manifest's
# `seed.source_commit` is checked out into a worktree, whose own manifest
# pins the PREVIOUS published seed, and `scripts/generations.sh build` in
# that worktree reproduces the candidate (the same deterministic stage0 ->
# stage1 -> stage2 the seed-release workflow performs). The result must
# match the pinned sha256 byte for byte, so this never installs an unpinned
# or stale artifact; it only removes the window in which every bump gate is
# red for a missing release (docs/bootstrap.md "Bootstrap bump procedure").
# Only that 404 is rebuilt: a release that exists but cannot be fetched or
# verified (bad manifest, missing asset, sha mismatch) stays fatal, and so
# does being offline (the probe cannot answer 404). Set
# VIBE_ENSURE_SEED_NO_REBUILD=1 to keep the fail-fast behavior for the 404
# too. CI callers should put an actions/cache step keyed on the seed sha256
# ahead of this so a warm runner never needs the network at all.
#
# Usage: scripts/ensure_seed.sh [--manifest PATH]
# Exits 0 (silently, after printing a one-line "already present" note)
# if the on-disk artifact already matches; otherwise fetches (or rebuilds)
# then re-verifies.

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

# Rebuild the pinned seed from `seed.source_commit` with the seed THAT commit
# pins (see the header). Writes the stage2 to $SEED_ARTIFACT_PATH; the caller
# verifies the sha256. VIBE_ENSURE_SEED_REBUILD_CMD replaces the worktree
# build for scripts/ensure_seed_test.sh only: it runs with the destination
# path as $1 and must write the artifact there.
rebuild_from_source_commit() {
  local source_commit short wt gen
  source_commit="$(read_manifest seed.source_commit || true)"
  [ -n "$source_commit" ] || die "release $SEED_TAG is not available and $MANIFEST has no seed.source_commit to rebuild from"
  mkdir -p "$(dirname "$SEED_ARTIFACT_PATH")"
  if [ -n "${VIBE_ENSURE_SEED_REBUILD_CMD:-}" ]; then
    echo "[ensure-seed] release $SEED_TAG not available; running VIBE_ENSURE_SEED_REBUILD_CMD (test hook)" >&2
    bash -c "$VIBE_ENSURE_SEED_REBUILD_CMD" rebuild "$SEED_ARTIFACT_PATH"
    return 0
  fi
  short="$(printf '%s' "$source_commit" | cut -c1-12)"
  # Per-invocation directories: two ensure_seed runs on the same manifest
  # (a test battery started while the seed is missing) must not wipe each
  # other's build; each installs the same pinned bytes or fails its own check.
  mkdir -p "$PROJECT_ROOT/_build/seed_rebuild"
  REBUILD_DIR="$(mktemp -d "$PROJECT_ROOT/_build/seed_rebuild/$short.XXXXXX")"
  wt="$REBUILD_DIR/src"
  gen="$REBUILD_DIR/gen"
  mkdir -p "$gen"
  echo "[ensure-seed] release $SEED_TAG not available; rebuilding the pinned seed from source_commit $short with the seed that commit pins (deterministic; the result must match sha256 $SEED_ARTIFACT_SHA)" >&2
  if ! git -C "$PROJECT_ROOT" cat-file -e "$source_commit^{commit}" 2>/dev/null; then
    git -C "$PROJECT_ROOT" fetch --depth 1 origin "$source_commit" || \
      die "cannot fetch source_commit $source_commit to rebuild seed $SEED_TAG"
  fi
  git -C "$PROJECT_ROOT" worktree prune
  git -C "$PROJECT_ROOT" worktree add --detach "$wt" "$source_commit" >&2 || \
    die "cannot check out source_commit $source_commit to rebuild seed $SEED_TAG"
  local prior_tag
  prior_tag="$(MANIFEST="$wt/bootstrap/seed.json" read_manifest seed.tag || true)"
  if [ "$prior_tag" = "$SEED_TAG" ] || [ -z "$prior_tag" ]; then
    die "source_commit $short pins '$prior_tag' itself; a rebuild needs a source commit whose manifest pins the previous published seed (publish release $SEED_TAG, or fix seed.source_commit)"
  fi
  # The worktree's own ensure_seed fetches $prior_tag; never recurse into a
  # second rebuild from there. VIBE_PROJECT_ROOT must name the worktree: an
  # exported root (the synthetic/policy runners set one) would otherwise make
  # generations.sh build this checkout, whose manifest pins the missing seed.
  # --skip-run-validation: the per-stage sample run needs wasmtime, which CI
  # jobs install after this step (or never); the sha256 pin below is the
  # validation of the rebuilt artifact.
  if ! (cd "$wt" && VIBE_PROJECT_ROOT="$wt" VIBE_ENSURE_SEED_NO_REBUILD=1 bash scripts/generations.sh build --skip-run-validation --out-dir "$gen" >&2); then
    die "rebuilding seed $SEED_TAG from source_commit $short failed (log above)"
  fi
  [ -f "$gen/stage2.wasm" ] || die "rebuild of seed $SEED_TAG produced no stage2.wasm in $gen"
  cp "$gen/stage2.wasm" "$SEED_ARTIFACT_PATH"
}

REBUILD_DIR=""
cleanup_rebuild_dir() {
  if [ -n "$REBUILD_DIR" ]; then
    git -C "$PROJECT_ROOT" worktree remove --force "$REBUILD_DIR/src" >/dev/null 2>&1 || true
    rm -rf "$REBUILD_DIR"
  fi
}

# HTTP status of the release's manifest asset (fetch_compiler.sh's first
# download, same default URL), probed with a one-byte GET range (HEAD on the
# redirected asset answers 401 even when it exists; measured 2026-09-05:
# published tag 206, missing tag 404). 404 = the release does not exist;
# anything else (206/200, 401, 000 offline) is not a reason to rebuild.
release_manifest_status() {
  local base="https://github.com/mizchi/vibe-lang/releases/download/$SEED_TAG"
  curl -sL --max-time 30 -r 0-0 -o /dev/null -w '%{http_code}' "$base/release-manifest.json" 2>/dev/null || printf '000'
}

fetch_out="$(mktemp -d)"
trap 'rm -rf "$fetch_out"; cleanup_rebuild_dir' EXIT
release_status="$(release_manifest_status)"
if [ "$release_status" = "404" ]; then
  if [ "${VIBE_ENSURE_SEED_NO_REBUILD:-0}" = "1" ]; then
    die "release $SEED_TAG does not exist (HTTP 404) and VIBE_ENSURE_SEED_NO_REBUILD=1 forbids rebuilding it from seed.source_commit"
  fi
  rebuild_from_source_commit
else
  bash "$SCRIPT_DIR/fetch_compiler.sh" "$SEED_TAG" --out-dir "$fetch_out" --no-module-source || \
    die "fetching release $SEED_TAG failed (manifest probe: HTTP $release_status); only a release that does not exist (404) is rebuilt from source, a published one that cannot be fetched or verified is fatal"
  fetched_wasm="$(find "$fetch_out" -maxdepth 1 -name '*.wasm' | head -1)"
  [ -n "$fetched_wasm" ] || die "fetch_compiler.sh did not produce a .wasm asset for tag $SEED_TAG"
  mkdir -p "$(dirname "$SEED_ARTIFACT_PATH")"
  cp "$fetched_wasm" "$SEED_ARTIFACT_PATH"
fi

actual="$(sha256_file "$SEED_ARTIFACT_PATH")"
[ "$actual" = "$SEED_ARTIFACT_SHA" ] || \
  die "artifact sha256 does not match the pin after fetch/rebuild: got=$actual want=$SEED_ARTIFACT_SHA"
echo "[ensure-seed] installed and verified: $SEED_ARTIFACT_REL (sha256=$actual)" >&2

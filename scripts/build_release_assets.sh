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

sha256_file() {
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif shasum -a 256 </dev/null >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "release-assets: sha256sum or shasum is required" >&2
    exit 1
  fi
}

# --- toolchain bundle (docs/install.md "Updating", #2678) --------------------
# The platform-independent part of toolchains/<name>/: the launcher, the pkg
# and warm-pool scripts, the LSP scripts, the context pack, and the stdlib
# packages `install/install.sh` materializes in checkout mode, with their
# package hashes computed by the compiler this release ships (the node host
# runner, no viberun needed). A release install unpacks this next to the
# runner tarball for the host and the compiler wasm.
TOOLCHAIN_NAME="vibe-toolchain-$TAG.tar.gz"
tc_stage="$OUT_DIR/.toolchain"
rm -rf "$tc_stage"
mkdir -p "$tc_stage/bin" "$tc_stage/lib"
install -m 0755 "$PROJECT_ROOT/runtime/vibe" "$tc_stage/bin/vibe"
install -m 0644 "$PROJECT_ROOT/scripts/vibe_pkg.sh" "$tc_stage/lib/vibe_pkg.sh"
install -m 0644 "$PROJECT_ROOT/scripts/parallel_warm_pool.sh" "$tc_stage/lib/parallel_warm_pool.sh"
for js in lsp_server.js symbol_index.js graph_query.js; do
  [ -f "$PROJECT_ROOT/clients/js/$js" ] && install -m 0644 "$PROJECT_ROOT/clients/js/$js" "$tc_stage/lib/$js"
done
bash "$PROJECT_ROOT/scripts/gen_context_pack.sh" "$PROJECT_ROOT" > "$tc_stage/lib/context-pack.md"
: > "$tc_stage/stdlib-hashes.tsv"
for pkg in @vibe/core @vibe/ast @vibe/parser @vibe/builtin @vibe/console @vibe/wit_runtime; do
  src="$PROJECT_ROOT/lib/$pkg"
  [ -f "$src/index.vpkg" ] || { echo "release-assets: stdlib package missing: $src" >&2; exit 1; }
  dest="$tc_stage/lib/$pkg"
  mkdir -p "$dest"
  cp "$src/index.vpkg" "$dest/"
  for f in "$src"/*.vibe; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      *_test.vibe|*_bench.vibe) ;;
      *) cp "$f" "$dest/" ;;
    esac
  done
  hash_out="$OUT_DIR/.hash.out"
  rm -f "$hash_out" "$hash_out.diag"
  VIBE_HASH=1 VIBE_PREOPEN_DIR="$PROJECT_ROOT" \
    bash "$SCRIPT_DIR/run_wasm_vibe_host_runner.sh" --invoke cli_main "$OUT_DIR/$WASM_NAME" \
      "$src/index.vpkg" "$hash_out" __no_entry__ >/dev/null 2>&1 || true
  pkg_hash="$(awk '/^package /{print $2}' "$hash_out" 2>/dev/null || true)"
  [ -n "$pkg_hash" ] || { cat "$hash_out.diag" >&2 2>/dev/null || true; echo "release-assets: package hash failed for $pkg" >&2; exit 1; }
  printf '%s\t%s\n' "$pkg" "$pkg_hash" >> "$tc_stage/stdlib-hashes.tsv"
  rm -f "$hash_out" "$hash_out.diag"
done
( cd "$tc_stage" && tar -czf "$OUT_DIR/$TOOLCHAIN_NAME" bin lib stdlib-hashes.tsv )
rm -rf "$tc_stage"

# --- runner tarballs -----------------------------------------------------
# One prebuilt `viberun` per target, built natively by the release workflow's
# matrix and dropped into $VIBE_RELEASE_RUNNERS_DIR as
# viberun-<tag>-<target>.tar.gz (each holding one executable, `viberun`).
# A local run of this script with no runners dir produces a manifest with
# no runners, which `vibe self update` refuses for the host with a clear
# message.
RUNNERS_DIR="${VIBE_RELEASE_RUNNERS_DIR:-$PROJECT_ROOT/dist/release/runners}"
runner_names=()
runner_targets=()
if [ -d "$RUNNERS_DIR" ]; then
  for f in "$RUNNERS_DIR"/viberun-"$TAG"-*.tar.gz; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    target="${name#viberun-$TAG-}"
    target="${target%.tar.gz}"
    cp "$f" "$OUT_DIR/$name"
    runner_names+=("$name")
    runner_targets+=("$target")
  done
fi
wasmtime_version="$(sed -n 's/^wasmtime = { version = "\([^"]*\)".*$/\1/p' "$PROJECT_ROOT/runtime/viberun/Cargo.toml" | head -1)"

# --- release manifest ------------------------------------------------------
# Every shipped asset with its sha256 (`assets`), the runner per target, and
# the wasmtime version the runners embed: what `vibe self update` and
# `install/install.sh --version` verify every downloaded byte against before
# anything is moved into toolchains/.
asset_lines="$OUT_DIR/.assets.tsv"
: > "$asset_lines"
for name in "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$TOOLCHAIN_NAME" ${runner_names[@]+"${runner_names[@]}"}; do
  printf '%s\t%s\n' "$name" "$(sha256_file "$OUT_DIR/$name")" >> "$asset_lines"
done
runner_lines="$OUT_DIR/.runners.tsv"
: > "$runner_lines"
i=0
while [ "$i" -lt "${#runner_names[@]}" ]; do
  printf '%s\t%s\n' "${runner_targets[$i]}" "${runner_names[$i]}" >> "$runner_lines"
  i=$((i + 1))
done
node - "$compiler_fragment" "$OUT_DIR/$MANIFEST_NAME" "$TAG" "$VERSION" "$commit_sha" \
  "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$TOOLCHAIN_NAME" "$wasmtime_version" \
  "$asset_lines" "$runner_lines" <<'NODE'
const fs = require("node:fs");
const [fragmentPath, outPath, tag, version, commit, wasmName, modsrcName, seedJsonName,
  toolchainName, wasmtime, assetLines, runnerLines] = process.argv.slice(2);
const compiler = JSON.parse(fs.readFileSync(fragmentPath, "utf8"));
const tsv = (p) => fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => l.split("\t"));
const assets = {};
for (const [name, sha] of tsv(assetLines)) assets[name] = sha;
const runners = {};
for (const [target, name] of tsv(runnerLines)) runners[target] = name;
const manifest = {
  tag,
  version,
  commit,
  wasmtime,
  compiler_wasm: wasmName,
  toolchain: toolchainName,
  runners,
  assets,
  artifacts: [wasmName, modsrcName, seedJsonName, toolchainName, ...Object.values(runners)],
  compiler,
};
fs.writeFileSync(outPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
rm -f "$compiler_fragment" "$asset_lines" "$runner_lines"

(
  cd "$OUT_DIR"
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$TOOLCHAIN_NAME" ${runner_names[@]+"${runner_names[@]}"} "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  else
    shasum -a 256 "$WASM_NAME" "$MODSRC_NAME" "$SEED_JSON_NAME" "$TOOLCHAIN_NAME" ${runner_names[@]+"${runner_names[@]}"} "$MANIFEST_NAME" \
      > "$CHECKSUM_NAME"
  fi
)

echo "[release-assets] staged assets:"
printf '  %s\n' \
  "$OUT_DIR/$WASM_NAME" \
  "$OUT_DIR/$MODSRC_NAME" \
  "$OUT_DIR/$SEED_JSON_NAME" \
  "$OUT_DIR/$TOOLCHAIN_NAME"
for name in ${runner_names[@]+"${runner_names[@]}"}; do printf '  %s\n' "$OUT_DIR/$name"; done
printf '  %s\n' \
  "$OUT_DIR/$MANIFEST_NAME" \
  "$OUT_DIR/$CHECKSUM_NAME"

#!/usr/bin/env bash
# Build a fresh selfhost CLI compiler wasm from the current committed source
# (seed -> stage1 -> stage2 via the Rust/node runner). The resulting
# stage2 wasm is the portable `vibe-cli.wasm` the installer ships and the runner
# AOT-compiles to a host-specific `.cwasm` (docs/install.md).
#
#   bash scripts/build_cli_wasm.sh [out.wasm]   # default: dist/cli/vibe-cli.wasm
#
# Content-fingerprint cache: stage0(seed)->stage1->stage2 is deterministic for
# a fixed (seed, lib/@vibe/**) pair (docs/bootstrap.md), so a rebuild against
# an unchanged tree just reproduces the same bytes. install.sh and every
# scripts/test_vibe_*.sh debugger/profiler smoke test call this script fresh
# per-invocation with no coordination between them -- in a single CI job that
# runs several of those sequentially (e.g. the `debug` smoke group's 7
# scripts), this used to mean 7 full seed->stage1->stage2 builds back to back
# for byte-identical output. Cache the stage2 artifact keyed on the git tree
# hash of `lib` + the seed pin; skip caching entirely (never a correctness
# risk, just no speedup) when either has uncommitted changes, since `HEAD:`
# tree hashing can't see working-tree edits. Opt out with
# VIBE_BUILD_CLI_WASM_NO_CACHE=1.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

out="${1:-$ROOT_DIR/dist/cli/vibe-cli.wasm}"
mkdir -p "$(dirname "$out")"

sha256_file() {
  # Probe by RUNNING it, not by `command -v`: a nix-shim `sha256sum` that is on
  # PATH but dies on a glibc mismatch passes an existence check and then fails
  # every call, so the fallback never engages and the caller dies instead.
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Prints a cache key on stdout and exits 0, or exits 1 (no output) if the
# tree is dirty / not a git checkout -- caller treats that as "don't cache".
cache_key() {
  [ "${VIBE_BUILD_CLI_WASM_NO_CACHE:-0}" != "1" ] || return 1
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  [ -z "$(git status --porcelain -- lib bootstrap/seed.json 2>/dev/null)" ] || return 1
  local lib_tree seed_hash
  lib_tree="$(git rev-parse HEAD:lib 2>/dev/null)" || return 1
  seed_hash="$(sha256_file bootstrap/seed.json)" || return 1
  printf '%s-%s\n' "$lib_tree" "$seed_hash"
}

cache_dir="${VIBE_BUILD_CLI_WASM_CACHE_DIR:-$ROOT_DIR/_build/cli_wasm_cache}"
if key="$(cache_key)"; then
  cached="$cache_dir/$key.wasm"
  if [ -s "$cached" ]; then
    cp "$cached" "$out"
    echo "[build-cli-wasm] cache hit ($key): reused $cached -> $out ($(wc -c <"$out") bytes)" >&2
    printf '%s\n' "$out"
    exit 0
  fi
else
  key=""
fi

echo "[build-cli-wasm] building selfhost compiler (seed -> stage1 -> stage2)…" >&2
# #1137: compile with entry_name=main so the shipped artifact's `_start`
# wraps a real `fn main -> Unit` (cli_adapter.vibe) with a genuine process
# exit code, instead of `_start` synthesized for `cli_main` (which only
# PRINTS its Int return, per ADR-0069). `cli_main` itself is unaffected --
# strip_executable_wasm always preserves it, and this override only affects
# this invocation, not the persisted seed manifest, so every other
# `generations.sh build` caller (gate, `pkf run generation`, ...) keeps
# building with entry_name=cli_main exactly as before.
bash scripts/generations.sh build --entry-name main >/dev/null

gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1 || true)"
[ -n "$gen" ] && [ -s "${gen}stage2.wasm" ] || {
  echo "[build-cli-wasm] error: stage2 wasm not produced" >&2
  exit 1
}

cp "${gen}stage2.wasm" "$out"
if [ -n "$key" ]; then
  mkdir -p "$cache_dir"
  cp "$out" "$cache_dir/$key.wasm"
fi
echo "[build-cli-wasm] wrote $out ($(wc -c <"$out") bytes)" >&2
printf '%s\n' "$out"

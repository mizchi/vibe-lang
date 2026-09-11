#!/usr/bin/env bash
# Build runtime/viberun only when its SOURCES actually changed -- by content.
#
# Three callers wanted "is the runner current?" and all three asked a question
# about TIMESTAMPS, which on a CI runner is the wrong question:
#
#   install/install.sh        `[ -x "$prebuilt" ]` -- any binary counts as current
#   test_gc_heap_accounting   `find src -newer "$RUNNER"` -- rebuild if newer
#   cargo itself              a local package's fingerprint is mtime+size based
#
# actions/checkout writes every source with mtime = now, and actions/cache
# restores target/ with the mtimes it was archived with. So the sources are
# ALWAYS newer than the restored binary, and the last two rebuild on every run
# while the first one never does. Measured on run 34579840316: the viberun
# cache restored in 5-7s and `cargo build --release` then took 205s
# (compiler-examples) and 239s (compiler-playground) anyway, with gc-gate
# paying its own rebuild inside the heap-accounting step.
#
# So ask the question the cache key already asks: hash the sources. A stamp
# beside the binary records the hash it was built from -- the same shape as
# ensure_generated.sh's .generated.stamp -- and it lives INSIDE target/release,
# so it travels with the cache it describes. `--check` reports without
# building; VIBE_VIBERUN_FORCE=1 rebuilds regardless.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT_DIR/runtime/viberun"
BIN="$CRATE/target/release/viberun"
STAMP="$CRATE/target/release/.viberun_srchash"

MODE="ensure"
for arg in "$@"; do
  case "$arg" in
    --check) MODE="check" ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
  esac
done

# Hashed from inside the crate so the value is a function of the CONTENT, not
# of where the checkout happens to live: an absolute path in the digest would
# make every runner disagree with every other one.
src_hash() {
  (
    cd "$CRATE"
    {
      find src -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum
      sha256sum Cargo.toml Cargo.lock 2>/dev/null || echo "MISSING manifest"
      # The toolchain is an input too: the same sources built by a different
      # rustc are a different binary, and a cache restored across a runner
      # image bump would otherwise read as current.
      rustc --version 2>/dev/null || echo "no rustc"
    } | sha256sum | cut -d' ' -f1
  )
}

want="$(src_hash)"

if [ -x "$BIN" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$want" ] \
   && [ "${VIBE_VIBERUN_FORCE:-0}" != "1" ]; then
  echo "[ensure-viberun] up to date ($want)"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo "[ensure-viberun] STALE or missing -- run: bash scripts/ensure_viberun.sh" >&2
  exit 1
fi

echo "[ensure-viberun] building ($want)"
# The stamp goes FIRST, so an interrupted build cannot leave a stamp vouching
# for a binary that was never linked.
rm -f "$STAMP"
cargo build --release --manifest-path "$CRATE/Cargo.toml"
if [ ! -x "$BIN" ]; then
  echo "[ensure-viberun] FAIL: cargo reported success but produced no $BIN" >&2
  exit 1
fi
printf '%s\n' "$want" > "$STAMP"
echo "[ensure-viberun] ok"

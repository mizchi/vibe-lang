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

# POSIX only -- no sha256sum, no -print0/sort -z/xargs -0 (Codex review of
# #2645). test_gc_heap_accounting.sh now calls this unconditionally, and that
# script is reachable from the public `pkf run test-gc-heap-accounting` task,
# so a GNU-only helper would break the gate on stock macOS before it checked
# anything. The probe-by-RUNNING idiom is ensure_seed.sh's, for its reason: a
# shim that is on PATH but dies on a glibc mismatch passes `command -v` and
# then fails every call.
hash_stdin() {
  if sha256sum </dev/null >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif shasum -a 256 </dev/null >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "[ensure-viberun] FAIL: sha256sum or shasum is required" >&2
    return 1
  fi
}

# Hashed from inside the crate so the value is a function of the CONTENT, not
# of where the checkout happens to live: an absolute path in the digest would
# make every runner disagree with every other one. The path is folded in beside
# each file's digest so a pure rename still moves the hash.
src_hash() {
  (
    cd "$CRATE"
    {
      find src -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s ' "$f"
        hash_stdin < "$f"
      done
      for m in Cargo.toml Cargo.lock; do
        printf '%s ' "$m"
        if [ -f "$m" ]; then hash_stdin < "$m"; else echo "MISSING"; fi
      done
      # The toolchain is an input too: the same sources built by a different
      # rustc are a different binary, and a cache restored across a runner
      # image bump would otherwise read as current.
      rustc --version 2>/dev/null || echo "no rustc"
    } | hash_stdin
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

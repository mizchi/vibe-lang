#!/usr/bin/env bash
# Smoke test for the checkout adapter of `vibe normalize`
# (scripts/vibe_normalize.sh): the CLI protocol -- --stdout / --check / write
# mode, a path with spaces, flags after the filename, the adapter ignoring a
# caller's compiler override, and the argument diagnostics.
#
# This script drives the COMMITTED SEED, so it asserts nothing that depends on
# which normalize engine the seed carries. #4027 replaced the engine: it used
# to write back a dead-code-eliminated, constant-folded program in section
# layout (an export-less file came back empty), and now only respells
# `recv.method(args)` as `Type::method(recv, args)` and keeps every other
# byte. The fixtures below hold under both, so the smoke stays green across
# the seed bump that adopts the new engine:
#
#   - `canon` is already canonical for both engines (all reachable from an
#     export, in section layout, no dot call), so each must leave it byte for
#     byte as it is;
#   - `dot` carries a same-file dot call, which both engines rewrite, so
#     --check must flag it.
#
# What the engine does is asserted against the CURRENT compiler instead: the
# normalize section of tests/gates/early/multi_file_fs_compile_regression.sh
# and lib/@vibe/compiler/tests/normalize_preserves_source_test.vibe.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_normalize_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/canon.vibe" <<'EOF'
//# Functions

let helper: () -> Int = () -> { 1 }

export let run: () -> Int = () -> { helper() }
EOF
cat > "$WORK/dot.vibe" <<'EOF'
struct Cart { items: Int }

export fn Cart::size(c: Cart) -> Int {
  c.items
}

export fn count(cart: Cart) -> Int {
  cart.size()
}
EOF

# --stdout prints a canonical file unchanged and leaves it alone.
bash "$ROOT_DIR/scripts/vibe_normalize.sh" --stdout "$WORK/canon.vibe" > "$WORK/canon.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/canon.vibe" "$WORK/canon.got.vibe"; then
  echo "[vibe-normalize-smoke] FAIL: --stdout changed a canonical file" >&2
  diff "$WORK/canon.vibe" "$WORK/canon.got.vibe" >&2 || true
  exit 1
fi

# --check: zero on a canonical file, nonzero on one with a dot call to respell.
if ! bash "$ROOT_DIR/scripts/vibe_normalize.sh" --check "$WORK/canon.vibe" >/dev/null 2>&1; then
  echo "[vibe-normalize-smoke] FAIL: --check rejected a canonical file" >&2; exit 1
fi
if bash "$ROOT_DIR/scripts/vibe_normalize.sh" --check "$WORK/dot.vibe" >/dev/null 2>&1; then
  echo "[vibe-normalize-smoke] FAIL: --check passed a file with a dot call to respell" >&2; exit 1
fi

# The CLI's write mode, a path with spaces, and flags after the filename: a
# canonical file is left byte for byte, and nothing is printed.
cp "$WORK/canon.vibe" "$WORK/space name.vibe"
bash "$ROOT_DIR/scripts/vibe_normalize.sh" "$WORK/space name.vibe" > "$WORK/write.out" 2> "$WORK/write.err"
cmp -s "$WORK/canon.vibe" "$WORK/space name.vibe"
[ ! -s "$WORK/write.out" ]
bash "$ROOT_DIR/scripts/vibe_normalize.sh" "$WORK/space name.vibe" --check

# Checkout adapters choose their compiler/runner explicitly; an installed or
# unrelated caller override must not silently select a different normalizer.
VIBE_CLI_WASM="$WORK/no-compiler.wasm" VIBE_RUNNER="$WORK/no-runner" \
  bash "$ROOT_DIR/scripts/vibe_normalize.sh" --stdout "$WORK/canon.vibe" > "$WORK/selected.out" 2> "$WORK/selected.err"
cmp -s "$WORK/canon.vibe" "$WORK/selected.out"

refuses() {
  local message="$1"; shift
  if bash "$ROOT_DIR/scripts/vibe_normalize.sh" "$@" > "$WORK/refused.out" 2> "$WORK/refused.err"; then
    echo "[vibe-normalize-smoke] FAIL: accepted $*" >&2; exit 1
  fi
  if ! grep -Fq "$message" "$WORK/refused.err"; then
    echo "[vibe-normalize-smoke] FAIL: missing diagnostic: $message" >&2
    cat "$WORK/refused.err" >&2; exit 1
  fi
  [ ! -s "$WORK/refused.out" ]
}
refuses 'takes ONE file' --stdout "$WORK/canon.vibe" "$WORK/dot.vibe"
refuses 'usage: vibe normalize'
refuses 'unknown flag: --unknown' --unknown "$WORK/canon.vibe"
refuses 'not found:' "$WORK/missing.vibe"
printf 'export let broken = (\n' > "$WORK/broken.vibe"
refuses 'error:' --stdout "$WORK/broken.vibe"

echo "[vibe-normalize-smoke] ok (check/write/stdout, CLI arguments, explicit seed, diagnostics)"

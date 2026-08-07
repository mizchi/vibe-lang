#!/usr/bin/env bash
# Smoke test for selfhost `vibe normalize` (scripts/vibe_normalize.sh).
# Mirrors the retired host normalize fixture 01 (order/DCE): dead-code
# elimination from exported roots, dropping the aggregate `export { .. }`,
# and section layout. Also asserts idempotency and that --check distinguishes
# normalized from un-normalized. (This script drives the COMMITTED SEED, so
# stage2-only behavior — module-block rejection #728, fn rejection #727 —
# is asserted in compiler_gate.sh step 6 instead.
#
# #1429 + bump to seed console-exception-rowvar-2026-08-06: the fixtures below
# USED to keep the BRACED effect row (`with { Error }`) deliberately, because
# this script drives the COMMITTED SEED rather than the current compiler, and
# the old seed both accepted the braced row and printed it back while the
# current compiler had already removed the spelling. That note carried an
# obligation: convert them IN THE SAME CHANGE that adopts a seed built from the
# current source -- earlier breaks this test against the very binary it pins,
# later leaves it broken after the bump.
#
# That change is this one. The adopted seed is built from post-#1429 source, so
# it rejects `with { .. }` outright ("the braced effect row was removed in
# #1429"). The rows below are now written `with Exception` -- #1461's canonical
# spelling, not the `with Error` the old note predicted, since that issue made
# `Exception` canonical after the note was written. Either spelling parses; the
# seed round-trips whichever one it is given VERBATIM (measured: `Error` in ->
# `Error` out, `Exception` in -> `Exception` out; it does not canonicalize the
# surface form), which is why input and expected output must carry the SAME
# spelling. The old module-flatten fixture 03 was retired with module blocks,
# #728.)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_normalize_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Fixture 01: ordering + DCE (`dead`, unused `type Alias`, aggregate export dropped).
cat > "$WORK/01.in.vibe" <<'EOF'
let dead: () -> Int = () -> { 0 }
import ./dep.vibe { dep }
trait Eq
impl Eq for Int
type Alias = Int
let helper: () -> Int = () -> { 1 }
export let run: () -> Int = () -> { helper() }
export let run_io: () -> Int with Exception = () -> { run() }
export { run, run_io }
EOF
cat > "$WORK/01.expected.vibe" <<'EOF'
//# Imports

import ./dep.vibe { dep }

//# Types

trait Eq

impl Eq for Int

//# Functions

let helper: () -> Int = () -> { 1 }

export let run: () -> Int = () -> { helper() }

export let run_io: () -> Int with Exception = () -> { run() }
EOF

# Aggregate-only export: `export { run }` is the sole export marker. `run` and
# its helper must survive DCE and `run` must be promoted to `export let` (the
# aggregate `export { .. }` statement itself is dropped).
cat > "$WORK/agg.in.vibe" <<'EOF'
let helper: () -> Int = () -> { 1 }
let run: () -> Int = () -> { helper() }
let dead: () -> Int = () -> { 2 }
export { run }
EOF
cat > "$WORK/agg.expected.vibe" <<'EOF'
//# Functions

let helper: () -> Int = () -> { 1 }

export let run: () -> Int = () -> { helper() }
EOF

# Lambda-annotation hoisting: old-syntax `let f = (x: T) -> R { body }` is
# canonicalized to `let f: (T) -> R = (x) -> { body }` (parameter + return types
# moved into the let annotation, stripped from the lambda).
cat > "$WORK/hoist.in.vibe" <<'EOF'
let id = (x: Int) -> Int { x }
export let run = () -> Int { id(1) }
export { run }
EOF
cat > "$WORK/hoist.expected.vibe" <<'EOF'
//# Functions

let id: (Int) -> Int = (x) -> { x }

export let run: () -> Int = () -> { id(1) }
EOF

# Generic lambda must NOT be hoisted: its `[T]` type params scope the lambda,
# not a let annotation, so hoisting would leave `T` unbound and the output would
# not compile. Left as-is (#609 review).
cat > "$WORK/generic.in.vibe" <<'EOF'
export let id = [T](x: T) -> T { x }
export { id }
EOF
cat > "$WORK/generic.expected.vibe" <<'EOF'
//# Functions

export let id = [T](x: T) -> T { x }
EOF

# Constant folding: `+ - *` over int literals are folded (respecting precedence,
# bottom-up): `1 + 2 * 3` -> `7`.
cat > "$WORK/fold.in.vibe" <<'EOF'
let x = 1 + 2 * 3
export let run = () -> Int { x }
export { run }
EOF
cat > "$WORK/fold.expected.vibe" <<'EOF'
//# Functions

let x: Int = 7

export let run: () -> Int = () -> { x }
EOF

# Literal type annotation: a `let` initialized by a literal (after folding) gets
# `: T`; a `let` initialized by something needing inference (a call) is left
# un-annotated; an already-annotated lambda binding is untouched.
cat > "$WORK/annot.in.vibe" <<'EOF'
let mk: () -> Int = () -> { 9 }
let lit = 3 + 4
let called = mk()
export let run = () -> Int { lit + called }
export { run }
EOF
cat > "$WORK/annot.expected.vibe" <<'EOF'
//# Functions

let mk: () -> Int = () -> { 9 }

let lit: Int = 7

let called = mk()

export let run: () -> Int = () -> { (lit + called) }
EOF

for case in 01 agg hoist generic fold annot; do
  bash "$ROOT_DIR/scripts/vibe_normalize.sh" --stdout "$WORK/$case.in.vibe" > "$WORK/$case.got.vibe" 2>/dev/null
  if ! cmp -s "$WORK/$case.expected.vibe" "$WORK/$case.got.vibe"; then
    echo "[vibe-normalize-smoke] FAIL: fixture $case mismatch" >&2
    diff "$WORK/$case.expected.vibe" "$WORK/$case.got.vibe" >&2 || true
    exit 1
  fi
  # Idempotency: normalize(normalize(x)) == normalize(x).
  cp "$WORK/$case.got.vibe" "$WORK/$case.got_in.vibe"
  bash "$ROOT_DIR/scripts/vibe_normalize.sh" --stdout "$WORK/$case.got_in.vibe" > "$WORK/$case.got2.vibe" 2>/dev/null
  if ! cmp -s "$WORK/$case.got.vibe" "$WORK/$case.got2.vibe"; then
    echo "[vibe-normalize-smoke] FAIL: fixture $case not idempotent" >&2; exit 1
  fi
done

# --check: nonzero on un-normalized input, zero on already-normalized output.
if bash "$ROOT_DIR/scripts/vibe_normalize.sh" --check "$WORK/01.in.vibe" >/dev/null 2>&1; then
  echo "[vibe-normalize-smoke] FAIL: --check passed un-normalized input" >&2; exit 1
fi
cp "$WORK/01.got.vibe" "$WORK/01.normalized.vibe"
if ! bash "$ROOT_DIR/scripts/vibe_normalize.sh" --check "$WORK/01.normalized.vibe" >/dev/null 2>&1; then
  echo "[vibe-normalize-smoke] FAIL: --check rejected normalized file" >&2; exit 1
fi

echo "[vibe-normalize-smoke] ok (fixtures 01 + agg + hoist + generic + fold + annot + idempotent + --check)"

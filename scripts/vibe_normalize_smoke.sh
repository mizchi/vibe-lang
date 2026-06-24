#!/usr/bin/env bash
# Smoke test for selfhost `vibe normalize` (scripts/vibe_normalize.sh).
# Mirrors the retired host normalize fixtures 01 (order/DCE) and 03 (module
# flatten): module flattening, dead-code elimination from exported roots,
# dropping the aggregate `export { .. }`, and section layout. Also asserts
# idempotency and that --check distinguishes normalized from un-normalized.
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
export let run_io: () -> Int with { Error } = () -> { run() }
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

export let run_io: () -> Int with { Error } = () -> { run() }
EOF

# Fixture 03: module flatten (`module math` => `math::*`) + intra-module DCE.
cat > "$WORK/03.in.vibe" <<'EOF'
export module math {
  let dead: () -> Int = () -> { 0 }
  let helper: () -> Int = () -> { 1 }
  export let run: () -> Int = () -> { helper() }
  export let run_io: () -> Int with { Error } = () -> { run() }
}
EOF
cat > "$WORK/03.expected.vibe" <<'EOF'
//# Functions

let math::helper: () -> Int = () -> { 1 }

export let math::run: () -> Int = () -> { math::helper() }

export let math::run_io: () -> Int with { Error } = () -> { math::run() }
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

for case in 01 03 agg hoist; do
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

echo "[vibe-normalize-smoke] ok (fixtures 01/03 + agg + hoist + idempotent + --check)"

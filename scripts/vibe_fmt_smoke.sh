#!/usr/bin/env bash
# Smoke test for selfhost `vibe fmt` (scripts/vibe_fmt.sh): formatting a messy
# file yields the canonical layout, the result is idempotent, and --check
# distinguishes formatted from unformatted.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK="$ROOT_DIR/_build/vibe_fmt_smoke"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

printf 'let   add=(a:Int,b:Int)->Int{a+b}\nlet classify=(n:Int)->Int{\nmatch n{0=>1,_=>2}\n}\n' \
  > "$WORK/messy.vibe"

cat > "$WORK/expected.vibe" <<'EOF'
let add = (a: Int, b: Int) -> Int {
  a + b
}
let classify = (n: Int) -> Int {
  match n {
    0 => 1,
    _ => 2
  }
}
EOF

bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/messy.vibe" > "$WORK/got.vibe" 2>/dev/null
if ! cmp -s "$WORK/expected.vibe" "$WORK/got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: canonical layout mismatch" >&2
  diff "$WORK/expected.vibe" "$WORK/got.vibe" >&2 || true
  exit 1
fi

# Idempotency: format(format(x)) == format(x).
cp "$WORK/got.vibe" "$WORK/got_in.vibe"
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/got_in.vibe" > "$WORK/got2.vibe" 2>/dev/null
if ! cmp -s "$WORK/got.vibe" "$WORK/got2.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: not idempotent" >&2; exit 1
fi

# --check: nonzero on messy, zero on already-formatted.
if bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$WORK/messy.vibe" >/dev/null 2>&1; then
  echo "[vibe-fmt-smoke] FAIL: --check passed an unformatted file" >&2; exit 1
fi
cp "$WORK/got.vibe" "$WORK/formatted.vibe"
if ! bash "$ROOT_DIR/scripts/vibe_fmt.sh" --check "$WORK/formatted.vibe" >/dev/null 2>&1; then
  echo "[vibe-fmt-smoke] FAIL: --check rejected a formatted file" >&2; exit 1
fi

# #628: import/export paths are a single token — no spaces around `/` or `.`,
# regardless of input spacing. Old fmt tokenized `/` as an operator and emitted
# `./a / b / index.vibe`.
cat > "$WORK/paths.in.vibe" <<'EOF'
import ./pkg/sub/index.vibe { a }
import .. / .. / core.vibe { b }
export ./lib/index.vibe { a, b }
EOF
cat > "$WORK/paths.expected.vibe" <<'EOF'
import ./pkg/sub/index.vibe {
  a
}
import ../../core.vibe {
  b
}
export ./lib/index.vibe {
  a, b
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/paths.in.vibe" > "$WORK/paths.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/paths.expected.vibe" "$WORK/paths.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: import/export path spacing (#628)" >&2
  diff "$WORK/paths.expected.vibe" "$WORK/paths.got.vibe" >&2 || true
  exit 1
fi

# Import-list items are sorted alphabetically (byte/codepoint order, so
# uppercase sorts before lowercase).
cat > "$WORK/sort.in.vibe" <<'EOF'
import @vibe/prelude { zeta_fn, alpha_fn, Middle::Thing, gamma_fn as g, type Beta }
EOF
cat > "$WORK/sort.expected.vibe" <<'EOF'
import @vibe/prelude {
  Middle::Thing, alpha_fn, gamma_fn as g, type Beta, zeta_fn
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/sort.in.vibe" > "$WORK/sort.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/sort.expected.vibe" "$WORK/sort.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: import-list items not sorted alphabetically" >&2
  diff "$WORK/sort.expected.vibe" "$WORK/sort.got.vibe" >&2 || true
  exit 1
fi

# An import-list line that would exceed 140 columns joined on one line wraps
# to one item per line instead.
cat > "$WORK/wrap.in.vibe" <<'EOF'
import @vibe/some/very/long/module/path/that/is/quite/deep { alpha_symbol_one, beta_symbol_two, gamma_symbol_three, delta_symbol_four, epsilon_symbol_five, zeta_symbol_six, eta_symbol_seven, theta_symbol_eight }
EOF
cat > "$WORK/wrap.expected.vibe" <<'EOF'
import @vibe/some/very/long/module/path/that/is/quite/deep {
  alpha_symbol_one,
  beta_symbol_two,
  delta_symbol_four,
  epsilon_symbol_five,
  eta_symbol_seven,
  gamma_symbol_three,
  theta_symbol_eight,
  zeta_symbol_six
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/wrap.in.vibe" > "$WORK/wrap.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/wrap.expected.vibe" "$WORK/wrap.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: long import-list did not wrap to one item per line" >&2
  diff "$WORK/wrap.expected.vibe" "$WORK/wrap.got.vibe" >&2 || true
  exit 1
fi

# A struct literal immediately after `export let x = ... -> Name { .. }` must
# NOT be mistaken for an import-list brace just because it follows a NAME
# token in a statement whose head keyword was `export` -- must stay a plain
# one-field-per-line block (c_brace_block), not the import-list wrap layout.
cat > "$WORK/not_import.in.vibe" <<'EOF'
export let make: () -> Foo = () -> Foo { field: 1 }
EOF
cat > "$WORK/not_import.expected.vibe" <<'EOF'
export let make: () -> Foo = () -> Foo {
  field: 1
}
EOF
bash "$ROOT_DIR/scripts/vibe_fmt.sh" --stdout "$WORK/not_import.in.vibe" > "$WORK/not_import.got.vibe" 2>/dev/null
if ! cmp -s "$WORK/not_import.expected.vibe" "$WORK/not_import.got.vibe"; then
  echo "[vibe-fmt-smoke] FAIL: struct literal after 'export let ... -> Name' misdetected as import list" >&2
  diff "$WORK/not_import.expected.vibe" "$WORK/not_import.got.vibe" >&2 || true
  exit 1
fi

echo "[vibe-fmt-smoke] ok (canonical + idempotent + --check + paths #628 + import sort/wrap)"

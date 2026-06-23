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

echo "[vibe-fmt-smoke] ok (canonical + idempotent + --check)"

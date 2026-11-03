#!/usr/bin/env bash
# Self-test for scripts/check_book_order.vibex (#2248, #3672).
#
# The gate had no self-test until the port (it was on
# gate_self_test_allowlist.txt). Each case mutates a copy of the real book/
# under _build/ (the gate reads only inside the repository) and asserts the
# gate fails for that defect, with the mutation checked to have landed first.
# The real book and the unmutated copy must pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_REL="_build/book_order_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[book-order-test] FAIL: $*" >&2; exit 1; }
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_book_order.vibex -- "$@" > "$WORK/out" 2>&1; }

gate || { cat "$WORK/out" >&2; fail "the real book must pass"; }
grep -q '^book-order: ok (' "$WORK/out" || { cat "$WORK/out" >&2; fail "the real book did not report ok"; }

tree="$WORK/tree"
copy_book() {
  rm -rf "$tree"
  mkdir -p "$tree"
  cp -R book "$tree/book"
}
expect_red() { # <case> <expected substring>
  if gate --root "$WORK_REL/tree"; then cat "$WORK/out" >&2; fail "$1: expected a failure, got ok"; fi
  grep -qF -- "$2" "$WORK/out" || { cat "$WORK/out" >&2; fail "$1: failed, but not with \"$2\""; }
  echo "[book-order-test] ok: $1"
}
# mutate <file> <python-expression over s>: rewrite a file, refusing a no-op.
mutate() {
  python3 - "$1" "$2" <<'PYEOF'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
t = eval(expr, {"s": s})
if t == s:
    sys.exit("mutation did not land: " + expr)
open(p, "w", encoding="utf-8").write(t)
PYEOF
}

copy_book
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "control: the unmutated copy must pass"; }

# The second chapter of the spine, and its neighbours.
second="$(grep -o 'en/[0-9][0-9]_[a-z_]*\.vibe\.md' book/SUMMARY.md | sed -n 2p)"
second="${second#en/}"
third="$(grep -o 'en/[0-9][0-9]_[a-z_]*\.vibe\.md' book/SUMMARY.md | sed -n 3p)"
third="${third#en/}"
[ -n "$second" ] && [ -n "$third" ] || fail "could not read the spine's second and third chapters"

# 1. A heading numbered against SUMMARY.
copy_book
mutate "$tree/book/en/$second" "s.replace('# 02 ', '# 05 ', 1)"
expect_red "a renumbered heading" "en/$second: H1 says chapter 05, but SUMMARY.md places it at 2"

# 2. A heading with no number.
copy_book
mutate "$tree/book/en/$second" "s.replace('# 02 — ', '# ', 1)"
expect_red "a heading with no number" "en/$second: the H1 must start with its chapter number"

# 3. A `Next:` footer that follows the file numbering instead of SUMMARY.
copy_book
mutate "$tree/book/en/$second" "s.replace('($third)', '(19_somewhere_else.vibe.md)', 1)"
expect_red "a Next: footer off the spine" "en/$second: Next: is 19_somewhere_else.vibe.md, want $third"

# 4. A translation whose footer is gone (ja/14..20 once had none).
copy_book
mutate "$tree/book/ja/$second" "'\n'.join(l for l in s.split('\n') if not l.startswith('次:'))"
expect_red "a translation with no 次: footer" "ja/$second: 次: is (absent), want $third"

# 5. A chapter SUMMARY lists that is not on disk.
copy_book
rm "$tree/book/en/$second"
expect_red "a listed chapter missing from book/en" "en/$second: listed in SUMMARY.md but not on disk"

# 6. A SUMMARY the gate can no longer read.
copy_book
mutate "$tree/book/SUMMARY.md" "s.replace('](en/', '](chapters/')"
expect_red "a SUMMARY with no readable spine" "read only 0 chapters out of SUMMARY.md"

# 7. A chapter with no translation is not this gate's question.
copy_book
rm "$tree/book/ja/$second"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "control: a missing translation must be skipped here"; }

# 8. A footer that names its target under ../en/ is the same chapter.
copy_book
mutate "$tree/book/ja/$second" "s.replace('($third)', '(../en/$third)', 1)"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "control: a ../en/ footer target must be read as the chapter"; }

echo "[book-order-test] ok (6 red cases and 4 controls, each mutation verified to land)"

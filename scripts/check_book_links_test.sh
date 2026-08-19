#!/usr/bin/env bash
# Self-test for check_book_links.sh. Each rule is proved Red on a tree built to
# violate it, so the checker cannot quietly stop checking.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
CHECK="$ROOT_DIR/scripts/check_book_links.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# $1 = expected exit, $2 = what it proves, $3 = substring the output must have
expect() {
  local want="$1" what="$2" needle="${3:-}"
  local out rc
  out="$(BOOK_DIR="$WORK/b" bash "$CHECK" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "book-links self-test: FAIL: $what -- exit $rc, wanted $want"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
    echo "book-links self-test: FAIL: $what -- output did not mention '$needle'"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  echo "  ok: $what"
}

fresh() { rm -rf "$WORK/b"; mkdir -p "$WORK/b/src" "$WORK/b/ja"; : > "$WORK/b/README.md"; }

# 1. A link that resolves.
fresh
: > "$WORK/b/src/02.md"
printf 'see [two](02.md)\n' > "$WORK/b/src/01.md"
expect 0 "a link that resolves passes"

# 2. A link that does not. This is the shape the whole Japanese book had.
fresh
printf 'next: [02](02_control_flow-ja.vibe.md)\n' > "$WORK/b/ja/01.md"
expect 1 "a broken link fails" "02_control_flow-ja.vibe.md"

# 3. Fenced code is not markdown. `fn identity[T](x: T) -> T` matches the link
#    grammar; reporting it would teach readers to ignore this checker.
fresh
printf 'text\n```vibe\nfn identity[T](x: T) -> T { x }\n```\nmore\n' > "$WORK/b/src/01.md"
expect 0 "a link-shaped expression inside a code fence is not a link"

# 4. ...but a broken link AFTER a fence still counts -- the fence must close.
fresh
printf '```vibe\nlet x = 1\n```\nsee [gone](nope.md)\n' > "$WORK/b/src/01.md"
expect 1 "the fence closes, so a later broken link is still caught" "nope.md"

# 5. External and in-page targets are not this checker's business.
fresh
printf '[web](https://example.com) [mail](mailto:a@b.c) [here](#section)\n' > "$WORK/b/src/01.md"
expect 0 "http, mailto and in-page anchors are skipped"

# 6. Only the file part is verified; a heading slug is not.
fresh
: > "$WORK/b/src/02.md"
printf '[two](02.md#some-heading)\n' > "$WORK/b/src/01.md"
expect 0 "an anchor on an existing file passes"

# 7. Relative traversal out of the chapter directory resolves normally.
fresh
mkdir -p "$WORK/b/../d" 2>/dev/null || true
printf '[index](../README.md)\n' > "$WORK/b/src/01.md"
expect 0 "a link up to the book index resolves"

# 8. A missing directory is an error, not a vacuous pass.
out="$(BOOK_DIR="$WORK/nonexistent" bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "book-links self-test: FAIL: a missing book directory passed instead of failing"
  fails=$((fails + 1))
else
  echo "  ok: a missing book directory is an error, not a skip"
fi

# 9. The real book passes.
if bash "$CHECK" >/dev/null 2>&1; then
  echo "  ok: the repository's own book resolves"
else
  echo "book-links self-test: FAIL: the repository's own book does not pass"
  bash "$CHECK" 2>&1 | sed 's/^/    /'
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "book-links self-test: $fails case(s) failed" >&2
  exit 1
fi
echo "book-links self-test: all cases passed"

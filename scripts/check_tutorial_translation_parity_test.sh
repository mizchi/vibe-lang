#!/usr/bin/env bash
# Self-test for scripts/check_tutorial_translation_parity.vibex (#2248, #3672).
#
# The gate had no self-test until the port (it was on
# gate_self_test_allowlist.txt). Each case mutates a copy of the real book/en
# and book/ja under _build/ (the gate reads only inside the repository) and
# asserts the gate fails for that defect; each mutation is checked to have
# landed first. The real tree and the unmutated copy must pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_REL="_build/tutorial_translation_parity_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "[tutorial-translation-parity-test] FAIL: $*" >&2; exit 1; }
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_tutorial_translation_parity.vibex -- "$@" > "$WORK/out" 2>&1; }

gate || { cat "$WORK/out" >&2; fail "the real tree must pass"; }
grep -q '^check-tutorial-translation-parity: ok (' "$WORK/out" || { cat "$WORK/out" >&2; fail "the real tree did not report ok"; }

tree="$WORK/tree"
copy_book() {
  rm -rf "$tree"
  mkdir -p "$tree/book"
  cp -R book/en "$tree/book/en"
  cp -R book/ja "$tree/book/ja"
}
expect_red() { # <case> <expected substring>
  if gate --root "$WORK_REL/tree"; then cat "$WORK/out" >&2; fail "$1: expected a failure, got ok"; fi
  grep -qF -- "$2" "$WORK/out" || { cat "$WORK/out" >&2; fail "$1: failed, but not with \"$2\""; }
  echo "[tutorial-translation-parity-test] ok: $1"
}

copy_book
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "control: the unmutated copy must pass"; }

# A chapter with ```output blocks, to mutate.
chapter="$(grep -l '^```output$' book/en/[0-9][0-9]_*.vibe.md | head -1)"
name="$(basename "$chapter")"
[ -n "$name" ] || fail "no chapter with an output block to mutate"

# 1. An output line changed in the translation only.
copy_book
awk 'f == 0 && prev == "```output" { print $0 "-drift"; f = 1; prev = $0; next } { print; prev = $0 }' \
  "book/ja/$name" > "$tree/book/ja/$name"
grep -q -- '-drift$' "$tree/book/ja/$name" || fail "drift: the mutation did not land"
expect_red "an output line that differs" "$name and its translation ran different programs"
grep -qF -- '-drift' "$WORK/out" || { cat "$WORK/out" >&2; fail "drift: the report does not show the differing line"; }

# 2. The same lines, split into two blocks: block boundaries are part of the
#    comparison.
copy_book
awk 'f == 0 && prev == "```output" { print; print "```"; print "```output"; f = 1; prev = ""; next } { print; prev = $0 }' \
  "book/ja/$name" > "$tree/book/ja/$name"
[ "$(grep -c '^```output$' "$tree/book/ja/$name")" -gt "$(grep -c '^```output$' "book/ja/$name")" ] \
  || fail "split block: the mutation did not land"
expect_red "an output block split in two" "$name and its translation ran different programs"

# 3. A chapter with no translation.
copy_book
rm "$tree/book/ja/$name"
expect_red "a chapter with no translation" "$name has no translation"

# 4. A translation with no chapter.
copy_book
cp "book/ja/$name" "$tree/book/ja/99_orphan.vibe.md"
expect_red "a translation with no chapter" "book/ja/99_orphan.vibe.md has no canonical English chapter"

# 5. Prose and comments may differ; only the output blocks are compared.
copy_book
printf '\nTranslated prose that the English file does not have.\n' >> "$tree/book/ja/$name"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "prose: a prose-only difference was refused"; }

# 6. A file that is not a chapter (no NN_ prefix) is not paired.
copy_book
printf '# notes\n```output\nx\n```\n' > "$tree/book/en/notes.vibe.md"
gate --root "$WORK_REL/tree" || { cat "$WORK/out" >&2; fail "non-chapter: a file without an NN_ prefix was paired"; }

# 7. No chapters at all.
mkdir -p "$WORK/empty/book/en"
if gate --root "$WORK_REL/empty"; then cat "$WORK/out" >&2; fail "empty: a book with no chapters passed"; fi
grep -qF 'no chapters found under book/en' "$WORK/out" || { cat "$WORK/out" >&2; fail "empty: failed for the wrong reason"; }

echo "[tutorial-translation-parity-test] ok (5 red cases and 4 controls, each mutation verified to land)"

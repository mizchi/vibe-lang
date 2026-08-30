#!/usr/bin/env bash
# Red test for scripts/check_treesitter_wasm_corpus.sh (#2248).
#
# The decisive case is the one a reviewer reproduced against the hash-only gate
# (#2422): regenerate src/parser.c alone, restamp, and every hash agrees while
# the wasm is still stale. This gate is what sees that, so its self-test uses
# the REAL historical artifacts -- the pre-`~` wasm from before the rebuild --
# rather than a synthetic mutation. Nothing models a stale binary as well as an
# actually stale binary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
GATE="$SCRIPT_DIR/check_treesitter_wasm_corpus.sh"

# An exported override from a session hook would point every case at the real
# tree and turn the whole suite into a no-op (#2252).
unset VIBE_TREESITTER_CORPUS_ROOT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ts_corpus.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CORPUS_REL="integrations/treesitter-vibe/test/corpus"
PLAY_REL="playground/public/tree-sitter-vibe.wasm"
ZED_REL="integrations/zed-vibe/grammars/vibe.wasm"
PKG_REL="playground/package.json"

# Share one web-tree-sitter install across the cases so this stays fast.
STAGE="$ROOT/_build/.wts"

fresh_tree() {
  local d="$WORK/$1"
  rm -rf "$d"
  mkdir -p "$d/$CORPUS_REL" "$d/playground/public" "$d/integrations/zed-vibe/grammars"
  cp "$ROOT/$CORPUS_REL"/*.txt "$d/$CORPUS_REL/"
  cp "$ROOT/$PLAY_REL" "$d/$PLAY_REL"
  cp "$ROOT/$ZED_REL"  "$d/$ZED_REL"
  cp "$ROOT/$PKG_REL"  "$d/$PKG_REL"
  # The stamper writes these two, so a tree it is pointed at needs them.
  mkdir -p "$d/integrations/treesitter-vibe/src"
  cp "$ROOT/integrations/treesitter-vibe/src/parser.c" "$d/integrations/treesitter-vibe/src/parser.c"
  cp "$ROOT/integrations/treesitter-vibe/generated.sha256" "$d/integrations/treesitter-vibe/generated.sha256"
  echo "$d"
}

run_gate() {
  VIBE_TREESITTER_CORPUS_ROOT="$1" VIBE_TREESITTER_WTS_DIR="$STAGE" bash "$GATE" >/dev/null 2>&1
}

fails=0
expect_fail() {
  if run_gate "$2"; then echo "  FAIL: gate accepted '$1'" >&2; fails=$((fails + 1));
  else echo "  ok: gate rejected '$1'"; fi
}
expect_pass() {
  if run_gate "$2"; then echo "  ok: gate accepted '$1'";
  else echo "  FAIL: gate rejected '$1'" >&2; fails=$((fails + 1)); fi
}

echo "[ts-corpus-test] control"
d="$(fresh_tree control)"
expect_pass "the committed artifacts" "$d"

# THE case: a wasm from before the grammar change. Taken from git rather than
# invented, so it is the artifact that actually shipped stale.
echo "[ts-corpus-test] a wasm from before the grammar change"
STALE="$WORK/stale_play.wasm"
if git -C "$ROOT" show "HEAD~1:$PLAY_REL" > "$STALE" 2>/dev/null && [ -s "$STALE" ]; then
  if cmp -s "$STALE" "$ROOT/$PLAY_REL"; then
    # HEAD~1 no longer carries a pre-rebuild wasm (this test outlived the
    # commit). Say so instead of passing on a comparison that proves nothing.
    echo "  BUG in this test: HEAD~1's wasm is identical to the current one," >&2
    echo "    so the 'stale' fixture is not stale. Repoint it at a commit" >&2
    echo "    before the wasm rebuild." >&2
    fails=$((fails + 1))
  else
    d="$(fresh_tree stale)"
    cp "$STALE" "$d/$PLAY_REL"
    expect_fail "the pre-rebuild playground wasm" "$d"

    # And the reviewer's scenario end to end: with that stale wasm in place,
    # the stamper must refuse rather than record it as current. Pointed at the
    # SCRATCH tree -- without that it proves the real one, which is green, and
    # any refusal would be for an unrelated reason.
    before="$(cat "$d/integrations/treesitter-vibe/generated.sha256")"
    if VIBE_TREESITTER_STAMP_ROOT="$d" VIBE_TREESITTER_WTS_DIR="$STAGE" \
        bash "$SCRIPT_DIR/stamp_treesitter_artifacts.sh" >/dev/null 2>&1; then
      echo "  FAIL: the stamper laundered a stale wasm" >&2
      fails=$((fails + 1))
    else
      echo "  ok: the stamper refused to stamp a stale wasm"
    fi
    # A refusal that still wrote is not a refusal.
    if [ "$before" != "$(cat "$d/integrations/treesitter-vibe/generated.sha256")" ]; then
      echo "  FAIL: the refused stamp still rewrote generated.sha256" >&2
      fails=$((fails + 1))
    else
      echo "  ok: the refusal left the stamp untouched"
    fi
    # The control for BOTH of the above: on a tree whose wasm is current, the
    # same invocation must succeed. Otherwise a stamper broken for any reason
    # would "pass" the two cases above.
    d2="$(fresh_tree stamp_control)"
    if VIBE_TREESITTER_STAMP_ROOT="$d2" VIBE_TREESITTER_WTS_DIR="$STAGE" \
        bash "$SCRIPT_DIR/stamp_treesitter_artifacts.sh" >/dev/null 2>&1; then
      echo "  ok: the stamper still stamps a current tree"
    else
      echo "  FAIL: the stamper refused a tree whose wasm is current" >&2
      fails=$((fails + 1))
    fi
  fi
else
  echo "  BUG in this test: could not read HEAD~1's wasm" >&2
  fails=$((fails + 1))
fi

# A wasm that does not load is the sharpest form of stale, and the committed Zed
# artifact was in exactly that state before the rebuild.
echo "[ts-corpus-test] a wasm that does not load"
d="$(fresh_tree unloadable)"
printf 'not a wasm module' > "$d/$ZED_REL"
expect_fail "an unloadable wasm" "$d"

# An empty corpus compares nothing and would otherwise pass everything.
echo "[ts-corpus-test] an empty corpus"
d="$(fresh_tree empty_corpus)"
rm -f "$d/$CORPUS_REL"/*.txt
expect_fail "a corpus with no cases" "$d"

# A corpus case the committed wasm cannot satisfy: the grammar moved, the
# artifact did not. Mutating the EXPECTATION stands in for that, and the
# mutation is verified to have landed first.
echo "[ts-corpus-test] a corpus expectation the wasm does not meet"
d="$(fresh_tree moved_grammar)"
sed -e 's/(integer)/(no_such_node)/' "$d/$CORPUS_REL/expressions.txt" > "$d/$CORPUS_REL/expressions.new"
mv "$d/$CORPUS_REL/expressions.new" "$d/$CORPUS_REL/expressions.txt"
if ! grep -q 'no_such_node' "$d/$CORPUS_REL/expressions.txt"; then
  echo "  BUG in this test: the corpus mutation did not land" >&2
  fails=$((fails + 1))
else
  expect_fail "a corpus the wasm does not match" "$d"
fi

echo "[ts-corpus-test] a missing artifact"
d="$(fresh_tree missing)"
rm -f "$d/$PLAY_REL"
expect_fail "a missing wasm" "$d"

if [ "$fails" -ne 0 ]; then
  echo "[ts-corpus-test] FAIL: $fails case(s)" >&2
  exit 1
fi
echo "[ts-corpus-test] ok"

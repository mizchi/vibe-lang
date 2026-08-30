#!/usr/bin/env bash
# Red test for scripts/check_treesitter_wasm_corpus.sh (#2248).
#
# The decisive case is the one a reviewer reproduced against the hash-only gate
# (#2422): regenerate src/parser.c alone, restamp, and every hash agrees while
# the wasm is still stale. This gate is what sees that, so its self-test uses a
# REAL stale artifact -- the pre-`~` playground wasm -- rather than a synthetic
# mutation. Nothing models a stale binary as well as an actually stale binary.
#
# That artifact is a committed fixture, not `git show HEAD~1:...`. The first
# version read it from history, which works in a full clone and fails on CI's
# shallow checkout: the run died with "could not read HEAD~1's wasm", a failure
# about the clone rather than about the property. That is the #2252 defect,
# committed inside the self-test written to enforce its sibling rule. A gate
# must not assume the environment it runs in.
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
LOCK_REL="playground/pnpm-lock.yaml"

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
  cp "$ROOT/$LOCK_REL" "$d/$LOCK_REL"
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

# THE case: a wasm from before the grammar change. A committed fixture, so it is
# the artifact that actually shipped stale and it is readable however the
# repository was cloned.
echo "[ts-corpus-test] a wasm from before the grammar change"
STALE="$ROOT/integrations/treesitter-vibe/test/fixtures/pre_tilde_playground.wasm"
if [ ! -s "$STALE" ]; then
  # Never a skip. A red test that cannot find its input has not passed.
  echo "  BUG in this test: missing fixture $STALE" >&2
  fails=$((fails + 1))
else
  if cmp -s "$STALE" "$ROOT/$PLAY_REL"; then
    # Someone "refreshed" the fixture. It is only useful while it is stale, so
    # say so instead of passing on a comparison that proves nothing.
    echo "  BUG in this test: the fixture is byte-identical to the committed" >&2
    echo "    wasm, so it is not stale and this case proves nothing." >&2
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

# The loader stage must follow playground/package.json. A presence-only check
# ("does node_modules/web-tree-sitter exist") reused an old install after the
# pin changed, so the gate proved the artifacts against the wrong loader
# (#2422 review). Drive both specs against ONE stage base and assert the second
# run staged the second version -- under the old logic it would still read the
# first.
echo "[ts-corpus-test] the loader stage follows the playground's LOCKFILE"
SPEC_STAGE="$WORK/spec_stage"
d="$(fresh_tree spec_a)"
if VIBE_TREESITTER_CORPUS_ROOT="$d" VIBE_TREESITTER_WTS_DIR="$SPEC_STAGE" bash "$GATE" >/dev/null 2>&1; then
  d2="$(fresh_tree spec_b)"
  # A version this repository does not pin, so reuse of the first stage is
  # visible rather than coincidentally right.
  OTHER="0.25.10"
  # Mutate the LOCKFILE -- that is what the gate reads, because it is what the
  # playground ships. The range in package.json is left alone on purpose, so
  # this case also proves the range is NOT what is followed.
  node -e '
    const fs = require("node:fs");
    const p = process.argv[1];
    const lines = fs.readFileSync(p, "utf8").split("\n");
    for (let i = 0; i < lines.length; i++) {
      if (!/^\s+web-tree-sitter:\s*$/.test(lines[i])) continue;
      for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
        if (/^\s+version:\s*\S+\s*$/.test(lines[j])) {
          lines[j] = lines[j].replace(/version:\s*\S+\s*$/, "version: " + process.argv[2]);
          fs.writeFileSync(p, lines.join("\n"));
          process.exit(0);
        }
      }
    }
    process.exit(3);
  ' "$d2/$LOCK_REL" "$OTHER"
  # Verify the mutation landed before believing anything that follows.
  if ! grep -q "version: $OTHER" "$d2/$LOCK_REL"; then
    echo "  BUG in this test: the lockfile mutation did not land" >&2
    fails=$((fails + 1))
  elif VIBE_TREESITTER_CORPUS_ROOT="$d2" VIBE_TREESITTER_WTS_DIR="$SPEC_STAGE" bash "$GATE" >/dev/null 2>&1; then
    staged="$(node -e '
      try {
        process.stdout.write(require(process.argv[1] + "/" + process.argv[2] + "/node_modules/web-tree-sitter/package.json").version);
      } catch (e) { process.stdout.write(""); }
    ' "$SPEC_STAGE" "$OTHER" 2>/dev/null)"
    if [ "$staged" = "$OTHER" ]; then
      echo "  ok: the changed lockfile staged web-tree-sitter $staged (the range was left at ^0.26.7)"
    else
      echo "  FAIL: the changed lockfile did not stage $OTHER (found '$staged')" >&2
      fails=$((fails + 1))
    fi
  else
    echo "  FAIL: the gate did not run under the changed lockfile" >&2
    fails=$((fails + 1))
  fi
else
  echo "  FAIL: the gate did not run under the repository's own lockfile" >&2
  fails=$((fails + 1))
fi

echo "[ts-corpus-test] a tree with no lockfile"
d="$(fresh_tree no_lock)"
rm -f "$d/$LOCK_REL"
expect_fail "no lockfile (must not fall back to the range)" "$d"

echo "[ts-corpus-test] a missing artifact"
d="$(fresh_tree missing)"
rm -f "$d/$PLAY_REL"
expect_fail "a missing wasm" "$d"

if [ "$fails" -ne 0 ]; then
  echo "[ts-corpus-test] FAIL: $fails case(s)" >&2
  exit 1
fi
echo "[ts-corpus-test] ok"

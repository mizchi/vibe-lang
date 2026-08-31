#!/usr/bin/env bash
# Red test for scripts/check_treesitter_artifacts.sh (#2248: a gate means
# nothing until it is shown it can fail).
#
# Every case mutates a REAL artifact in a scratch copy of the tree and asserts
# the gate rejects it. Each mutation is verified to have landed before the
# gate's verdict is believed -- a `sed` that matches nothing produces a red test
# that passes while proving nothing, which is how #2248's own red tests went
# green without covering anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
GATE="$SCRIPT_DIR/check_treesitter_artifacts.sh"

# Inherited state is the other way these go quietly wrong (#2252): a variable
# exported by a session hook silently redirects the gate at the real tree, so
# every "FAIL" below would be measuring the same unmutated files.
unset VIBE_TREESITTER_ARTIFACTS_ROOT

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ts_artifacts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAMP_REL="integrations/treesitter-vibe/generated.sha256"
PARSER_REL="integrations/treesitter-vibe/src/parser.c"
PLAY_REL="playground/public/tree-sitter-vibe.wasm"
ZED_REL="integrations/zed-vibe/grammars/vibe.wasm"

fresh_tree() {
  local d="$WORK/$1"
  rm -rf "$d"
  mkdir -p "$d/integrations/treesitter-vibe/src" \
           "$d/playground/public" \
           "$d/integrations/zed-vibe/grammars"
  cp "$ROOT/$STAMP_REL"  "$d/$STAMP_REL"
  cp "$ROOT/$PARSER_REL" "$d/$PARSER_REL"
  cp "$ROOT/$PLAY_REL"   "$d/$PLAY_REL"
  cp "$ROOT/$ZED_REL"    "$d/$ZED_REL"
  echo "$d"
}

fails=0

# Assert the mutation actually changed the file. Without this the whole suite
# can pass on a no-op edit.
assert_changed() {
  local label="$1" orig="$2" now="$3"
  if cmp -s "$orig" "$now"; then
    echo "  BUG in this test: mutation for '$label' changed nothing" >&2
    fails=$((fails + 1))
    return 1
  fi
  return 0
}

expect_fail() {
  local label="$1" dir="$2"
  if VIBE_TREESITTER_ARTIFACTS_ROOT="$dir" bash "$GATE" >/dev/null 2>&1; then
    echo "  FAIL: gate accepted '$label'" >&2
    fails=$((fails + 1))
  else
    echo "  ok: gate rejected '$label'"
  fi
}

expect_pass() {
  local label="$1" dir="$2"
  if VIBE_TREESITTER_ARTIFACTS_ROOT="$dir" bash "$GATE" >/dev/null 2>&1; then
    echo "  ok: gate accepted '$label'"
  else
    echo "  FAIL: gate rejected '$label', which is the unmutated tree" >&2
    fails=$((fails + 1))
  fi
}

echo "[ts-artifacts-test] control"
d="$(fresh_tree control)"
expect_pass "unmutated tree" "$d"

# The #2409 case itself: the C parser is regenerated, the wasm is not.
echo "[ts-artifacts-test] parser.c regenerated without rebuilding the wasm"
d="$(fresh_tree drift_parser)"
printf '\n/* a regenerated table would differ here */\n' >> "$d/$PARSER_REL"
assert_changed "parser drift" "$ROOT/$PARSER_REL" "$d/$PARSER_REL" \
  && expect_fail "parser.c off its stamp" "$d"

# The mirror image: a wasm swapped in without regenerating from the same src/.
echo "[ts-artifacts-test] a wasm replaced on its own"
d="$(fresh_tree drift_wasm)"
printf 'x' >> "$d/$PLAY_REL"
assert_changed "playground wasm drift" "$ROOT/$PLAY_REL" "$d/$PLAY_REL" \
  && expect_fail "playground wasm off its stamp" "$d"

d="$(fresh_tree drift_zed)"
printf 'x' >> "$d/$ZED_REL"
assert_changed "zed wasm drift" "$ROOT/$ZED_REL" "$d/$ZED_REL" \
  && expect_fail "zed wasm off its stamp" "$d"

# The silent ABI downgrade: 0.24.x emits 14, and nothing else errors.
echo "[ts-artifacts-test] ABI downgraded to 14"
d="$(fresh_tree abi14)"
sed -e 's/^#define LANGUAGE_VERSION 15$/#define LANGUAGE_VERSION 14/' \
    "$d/$PARSER_REL" > "$d/$PARSER_REL.new" && mv "$d/$PARSER_REL.new" "$d/$PARSER_REL"
if ! grep -q '^#define LANGUAGE_VERSION 14$' "$d/$PARSER_REL"; then
  echo "  BUG in this test: the ABI mutation did not land" >&2
  fails=$((fails + 1))
else
  expect_fail "ABI 14 parser" "$d"
fi

# A 0.24-shaped body whose #define was edited to look current. The version
# number alone would accept this.
echo "[ts-artifacts-test] 0.24-shaped body with a hand-edited version number"
d="$(fresh_tree abi_field)"
sed -e 's/\.abi_version = LANGUAGE_VERSION/.version = LANGUAGE_VERSION/' \
    "$d/$PARSER_REL" > "$d/$PARSER_REL.new" && mv "$d/$PARSER_REL.new" "$d/$PARSER_REL"
if grep -q '\.abi_version = LANGUAGE_VERSION' "$d/$PARSER_REL"; then
  echo "  BUG in this test: the .abi_version mutation did not land" >&2
  fails=$((fails + 1))
else
  # The number still reads 15, so only the field check can reject this.
  grep -q '^#define LANGUAGE_VERSION 15$' "$d/$PARSER_REL" \
    || { echo "  BUG in this test: the version number should be untouched" >&2; fails=$((fails + 1)); }
  expect_fail "0.24-shaped body claiming ABI 15" "$d"
fi

# A stamp that lists nothing compares nothing and would otherwise pass.
echo "[ts-artifacts-test] an under-populated stamp"
d="$(fresh_tree short_stamp)"
grep -v 'vibe\.wasm' "$d/$STAMP_REL" > "$d/$STAMP_REL.new" && mv "$d/$STAMP_REL.new" "$d/$STAMP_REL"
if [ "$(grep -c '  ' "$d/$STAMP_REL" || true)" -ge 3 ]; then
  echo "  BUG in this test: the stamp was not shortened" >&2
  fails=$((fails + 1))
else
  expect_fail "stamp listing fewer than 3 artifacts" "$d"
fi

# Counting stamp lines was a proxy for "all three are covered", and it broke as
# proxies do: a stamp that lost the Zed entry and gained a second playground
# entry still reached three (#2422 review). Measured with the Zed wasm ALSO
# corrupted -- the gate reported ok and never looked at it.
echo "[ts-artifacts-test] a duplicate entry standing in for a missing one"
d="$(fresh_tree dup_stamp)"
sed -e 's#integrations/zed-vibe/grammars/vibe.wasm#playground/public/tree-sitter-vibe.wasm#' \
  "$d/$STAMP_REL" > "$d/$STAMP_REL.new" && mv "$d/$STAMP_REL.new" "$d/$STAMP_REL"
# Corrupt the now-unstamped artifact, so a gate that really checks all three
# must reject this tree on either ground.
printf 'x' >> "$d/$ZED_REL"
if [ "$(grep -c 'playground/public/tree-sitter-vibe.wasm' "$d/$STAMP_REL")" -ne 2 ]; then
  echo "  BUG in this test: the stamp does not hold the duplicate" >&2
  fails=$((fails + 1))
else
  expect_fail "a stamp with a duplicate and a missing entry" "$d"
fi

# The alien entry must name a file that EXISTS and whose hash is CORRECT.
# Otherwise the old counting form rejects it too -- for "missing artifact" or a
# hash mismatch -- and the case passes without isolating the path check at all.
echo "[ts-artifacts-test] a stamp naming a path outside the three"
d="$(fresh_tree alien_stamp)"
mkdir -p "$d/some/other"
printf 'not an artifact\n' > "$d/some/other/file.txt"
alien_hash="$( (sha256sum "$d/some/other/file.txt" 2>/dev/null || shasum -a 256 "$d/some/other/file.txt") | awk '{print $1}' )"
printf '%s  some/other/file.txt\n' "$alien_hash" >> "$d/$STAMP_REL"
# Verify the fixture is one the OLD form would have accepted: the file is there
# and its hash matches, so nothing but the path check can reject it.
if [ ! -f "$d/some/other/file.txt" ] || [ -z "$alien_hash" ]; then
  echo "  BUG in this test: the alien fixture is not a hashable existing file" >&2
  fails=$((fails + 1))
else
  expect_fail "a stamp naming an unexpected path" "$d"
fi

echo "[ts-artifacts-test] a stamped artifact deleted"
d="$(fresh_tree missing)"
rm -f "$d/$ZED_REL"
expect_fail "missing zed wasm" "$d"

if [ "$fails" -ne 0 ]; then
  echo "[ts-artifacts-test] FAIL: $fails case(s)" >&2
  exit 1
fi
echo "[ts-artifacts-test] ok"

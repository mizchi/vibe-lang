#!/usr/bin/env bash
# Prove each committed tree-sitter wasm artifact against the corpus, by PARSING.
#
# scripts/check_treesitter_artifacts.sh compares hashes to a stamp, which pins
# the three artifacts to each other but not to the grammar: the stamp is a file
# in the tree, so regenerating only src/parser.c and then restamping produces a
# manifest where everything agrees while the wasm is still stale (#2422 review).
# That is the #2409 failure exactly, and no amount of hashing can see it.
#
# Behaviour can. A wasm built before a grammar change parses the new corpus case
# wrongly, and the corpus is the same file `tree-sitter test` proves the C parser
# against -- so this asks both wasm artifacts the question the C parser is
# already asked. Measured on the real historical artifacts: the pre-`~`
# playground wasm answers `(source_file (ERROR) ...)` where the corpus records
# `(unary_expression ...)`, and the pre-`~` Zed wasm does not load at all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${VIBE_TREESITTER_CORPUS_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$ROOT"

CORPUS="integrations/treesitter-vibe/test/corpus"
CHECKER="$SCRIPT_DIR/treesitter/wasm_corpus_check.mjs"
WASMS="playground/public/tree-sitter-vibe.wasm integrations/zed-vibe/grammars/vibe.wasm"

fail() { echo "[treesitter-wasm-corpus] FAIL: $*" >&2; exit 1; }

[ -d "$CORPUS" ] || fail "missing corpus: $CORPUS"
[ -f "$CHECKER" ] || fail "missing checker: $CHECKER"

# Probe by RUNNING it: a shim on PATH that dies on first use passes a
# `command -v` lookup and fails this gate for an unrelated reason.
node --version >/dev/null 2>&1 || fail "node is required to load a tree-sitter wasm grammar"

# The loader version is the PLAYGROUND'S, read from its manifest rather than
# pinned here -- checking against a different loader than the one that ships
# would answer a question nobody asked.
WTS_SPEC="$(node -e '
  const d = require("./playground/package.json");
  const v = (d.dependencies || {})["web-tree-sitter"];
  if (!v) { process.exit(3); }
  process.stdout.write(v);
' 2>/dev/null)" || fail "playground/package.json declares no web-tree-sitter dependency"

# Resolved to an absolute path BEFORE it is used. An override may be absolute
# or relative, and pasting either onto $ROOT produced `/scratch//home/...`,
# which then failed to resolve the loader -- and the gate reported that as "the
# wasm does not parse the corpus". Failing for a reason unrelated to the
# property, with a message naming the property, is the defect in #2252, met
# here in the gate written under its rule.
STAGE_IN="${VIBE_TREESITTER_WTS_DIR:-$ROOT/_build/.wts}"
case "$STAGE_IN" in
  /*) STAGE="$STAGE_IN" ;;
  *)  STAGE="$ROOT/$STAGE_IN" ;;
esac

if [ ! -d "$STAGE/node_modules/web-tree-sitter" ]; then
  mkdir -p "$STAGE"
  echo '{"name":"vibe-wts-stage","private":true}' > "$STAGE/package.json"
  # Never skipped when unavailable. A gate that cannot run has not answered,
  # and "unchecked" must not be able to look like "safe" (#2248).
  (cd "$STAGE" && npm install --no-audit --no-fund --silent "web-tree-sitter@$WTS_SPEC" >/dev/null 2>&1) \
    || fail "could not install web-tree-sitter@$WTS_SPEC into $STAGE
  This gate parses the corpus with the real loader; it does not have a
  degraded mode, because a skipped run and a passing run must not look alike."
fi

# Separate "the loader is not usable" from "the artifacts are wrong" while the
# two can still be told apart. Past this point every failure is about a wasm.
node -e '
  const { createRequire } = require("node:module");
  createRequire(process.argv[1])("web-tree-sitter");
' "$STAGE/package.json" >/dev/null 2>&1 \
  || fail "web-tree-sitter is not loadable from $STAGE
  This is a toolchain problem, NOT a verdict about the committed artifacts --
  remove that directory and re-run so it is reinstalled."

for w in $WASMS; do
  [ -f "$w" ] || fail "missing wasm artifact: $w"
done

# shellcheck disable=SC2086
VIBE_WTS_REQUIRE_BASE="$STAGE/package.json" \
  node "$CHECKER" "$CORPUS" $WASMS \
  || fail "a committed wasm does not parse the corpus the way the grammar says.
  Rebuild both wasm files from the current src/ and restamp:
    cd integrations/treesitter-vibe && pnpm install && pnpm run build:wasm
  (needs emcc on PATH or a running docker daemon). Do not restamp without
  rebuilding -- the stamper refuses anyway, which is what closes the gap
  hashing alone left."

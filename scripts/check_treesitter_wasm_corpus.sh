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

# The loader version is the PLAYGROUND'S -- and specifically the one it SHIPS,
# which is the resolution in its lockfile, not the range in its manifest. Those
# differ: `^0.26.7` currently installs 0.26.13 while the playground is locked to
# 0.26.7, so reading the range would bless the artifacts with a runtime no user
# receives (#2422 review). Nothing here pins a version of its own; checking
# against a loader other than the one that ships answers a question nobody
# asked.
WTS_SPEC="$(node -e '
  const fs = require("node:fs");
  const lines = fs.readFileSync("playground/pnpm-lock.yaml", "utf8").split("\n");
  // The importers section spells a dependency as three lines:
  //     web-tree-sitter:
  //       specifier: <range>
  //       version: <resolved>
  // Read the resolved one. pnpm may append peer context in parentheses.
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s+web-tree-sitter:\s*$/.test(lines[i])) continue;
    for (let j = i + 1; j < Math.min(i + 5, lines.length); j++) {
      const m = /^\s+version:\s*(\S+)\s*$/.exec(lines[j]);
      if (m) { process.stdout.write(m[1].split("(")[0]); process.exit(0); }
    }
  }
  process.exit(3);
' 2>/dev/null)" || fail "cannot read the resolved web-tree-sitter version from playground/pnpm-lock.yaml
  Refusing to fall back to the RANGE in package.json: that is the defect this
  reads the lockfile to avoid, and a quiet fallback would hide it."

# Resolved to an absolute path BEFORE it is used. An override may be absolute
# or relative, and pasting either onto $ROOT produced `/scratch//home/...`,
# which then failed to resolve the loader -- and the gate reported that as "the
# wasm does not parse the corpus". Failing for a reason unrelated to the
# property, with a message naming the property, is the defect in #2252, met
# here in the gate written under its rule.
STAGE_BASE_IN="${VIBE_TREESITTER_WTS_DIR:-$ROOT/_build/.wts}"
case "$STAGE_BASE_IN" in
  /*) STAGE_BASE="$STAGE_BASE_IN" ;;
  *)  STAGE_BASE="$ROOT/$STAGE_BASE_IN" ;;
esac

# The stage is keyed BY the requested spec, not merely checked against it. A
# presence-only test ("does node_modules/web-tree-sitter exist") reused an old
# install after playground/package.json changed version, so the gate proved the
# artifacts against the wrong loader and the stamper could stamp on that basis
# (#2422 review). Reusing the answer to "does a directory exist" for "is this
# the loader we asked for" is a proxy; keying the path on the spec removes the
# question instead of adding a second check for it. A changed spec is a
# different directory, so a stale stage cannot be picked up at all.
STAGE_KEY="$(printf '%s' "$WTS_SPEC" | tr -c 'A-Za-z0-9._-' '_')"
STAGE="$STAGE_BASE/$STAGE_KEY"

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

# The spec is an exact version now, so the staged install can be compared to it
# outright rather than merely reported. The directory key makes a stale stage
# unreachable; this catches the rest -- a partial install, a hand-edited stage,
# a registry that served something else.
WTS_VERSION="$(node -e '
  process.stdout.write(require(process.argv[1] + "/node_modules/web-tree-sitter/package.json").version);
' "$STAGE" 2>/dev/null)" || WTS_VERSION=""
[ -n "$WTS_VERSION" ] || fail "cannot read the staged web-tree-sitter version in $STAGE
  This is a toolchain problem, NOT a verdict about the committed artifacts --
  remove that directory and re-run."
if [ "$WTS_VERSION" != "$WTS_SPEC" ]; then
  fail "staged web-tree-sitter $WTS_VERSION, but playground/pnpm-lock.yaml resolves $WTS_SPEC
  Again a toolchain problem, not a verdict about the artifacts. Remove $STAGE
  and re-run."
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
  || fail "a committed wasm does not parse the corpus the way the grammar says
  (loader: web-tree-sitter $WTS_VERSION, as playground/pnpm-lock.yaml resolves it).
  Rebuild both wasm files from the current src/ and restamp:
    cd integrations/treesitter-vibe && pnpm install && pnpm run build:wasm
  (needs emcc on PATH or a running docker daemon). Do not restamp without
  rebuilding -- the stamper refuses anyway, which is what closes the gap
  hashing alone left."

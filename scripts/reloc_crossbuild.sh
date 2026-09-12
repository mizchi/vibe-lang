#!/usr/bin/env bash
# #2669: relocate one build's bodies onto ANOTHER build's index assignment,
# and compare against what the compiler emitted for that assignment.
#
#   bash scripts/reloc_crossbuild.sh [a.wasm b.wasm]
#
# With no arguments it builds the pair itself: the compiler's own closure, and
# the same closure with one import added to `lib/@vibe/core/base64.vibe` --
# which pulls `hex.vibe` earlier in the module order and moves most of the
# function index space. That is the edit class #2669 measured as the hardest:
# two distinct index deltas, one large and negative.
#
# Forcing a reorder REQUIRES editing at least one existing body (something has
# to call across the new import), so a small number of mismatches are genuine
# source changes rather than relocation failures. The edit is kept to one
# function and named in the output below, so the figure can be read with that
# in mind rather than silently inflated.
#
# The vibex REFUSES a vacuous run, in two steps. It fails when no shared
# function changed index -- two builds with the same assignment relocate
# perfectly by doing nothing, and handing it one module twice reports
# `matched=4351 mismatched=0 moved_index=0` and then fails. It ALSO fails when
# no body was both rewritten and byte-identical: a function's own index is not
# encoded in its body, so a moved assignment does not mean any body was
# rewritten, and bodies referencing only functions that held still are rebuilt
# by an identity operation. `rewritten_matched` is the figure the result rests
# on; `matched` includes those identity rebuilds and reads higher.
#
# Not a `check_*` gate, same as scripts/reloc_roundtrip.sh: it builds the
# compiler's whole closure twice, which is minutes, for a measurement rather
# than a pass/fail property. It still FAILS rather than reporting a clean run
# when it cannot answer -- a build that does not produce a module, or a pair
# sharing no named function, stops it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2 reloc-crossbuild "${RELOC_CROSSBUILD_STAGE2:-}")"

# Exactly 0, 2 or 3 arguments. Anything else is a typo, and the two ways this
# used to absorb one were both silent: ONE path fell through to the default
# builds and reported a confident measurement of an entirely different pair,
# and a FOURTH argument was accepted and dropped. A measurement tool that
# answers a question nobody asked is worse than one that refuses.
case "$#" in
  0|2|3) ;;
  *)
    echo "reloc-crossbuild: usage: $0 [a.wasm b.wasm [edited,fn,names]]" >&2
    echo "                  (no arguments builds the pair itself)" >&2
    exit 2
    ;;
esac

# An explicitly supplied pair. A third argument names comma-separated functions
# whose SOURCE differs between the two modules, to be excluded from the
# statistics (see the vibex); without one, nothing is excluded.
if [ "$#" -ge 2 ]; then
  VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/vibe_run.sh scripts/reloc_crossbuild.vibex -- "$1" "$2" ${3:+"$3"}
  exit $?
fi

CORPUS="${RELOC_CROSSBUILD_CORPUS:-lib/@vibe/compiler/tests/codegen_lexer_test.vibe}"
LEAF=lib/@vibe/core/base64.vibe
work="_build/_reloc_crossbuild"
mkdir -p "$work"
cp "$LEAF" "$work/leaf.orig"
trap 'cp "$work/leaf.orig" "$LEAF"' EXIT

build() { # <tag>
  local out="$work/$1.wasm"
  rm -f "$out"
  local rc=0
  env -u VIBE_RC -u VIBE_BACKEND VIBE_WASM_NAMES=1 VIBE_BUILD_CACHE_DIR="$work/cache_$1" \
    VIBE_PREOPEN_DIR="$ROOT_DIR" VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main "$STAGE2" \
    "$CORPUS" "$out" __no_entry__ >"$work/$1.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
    echo "reloc-crossbuild: FAIL: build $1 produced no module (exit $rc)" >&2
    exit 1
  fi
}

build a
python3 - "$LEAF" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
assert s.count('//# Functions\n') == 1
s = s.replace('//# Functions\n',
              '//# Imports\n\nimport ./hex.vibe {\n  hex_encode\n}\n\n//# Functions\n', 1)
anchor = 'export fn encode_url_safe('
assert s.count(anchor) == 1
s = s.replace(anchor,
              'fn b64_hex_bridge() -> Int {\n  String::length(hex_encode(""))\n}\n\n'
              + anchor, 1)
m = re.search(r'export fn encode_url_safe\([^)]*\)[^\{]*\{\n', s)
assert m
s = s[:m.end()] + '  let _bridge = b64_hex_bridge()\n' + s[m.end():]
open(p, 'w').write(s)
PY
build b
cp "$work/leaf.orig" "$LEAF"

echo "[reloc-crossbuild] the reordering edit touches ONE existing body:"
echo "                   encode_url_safe (one added let). It is EXCLUDED from"
echo "                   the statistics below -- its two versions are different"
echo "                   source programs, so comparing them measures the edit."
# The third argument names the function this wrapper EDITED. Its two versions
# are different source programs, so comparing them would measure the edit and
# not relocation; the vibex excludes it from the statistics and FAILS if the
# name matches nothing, so a rename here cannot silently put it back.
VIBE_PREOPEN_DIR="$ROOT_DIR" bash scripts/vibe_run.sh scripts/reloc_crossbuild.vibex -- \
  "$work/a.wasm" "$work/b.wasm" encode_url_safe

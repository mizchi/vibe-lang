#!/usr/bin/env bash
# check_grep_chunked_sweep.sh -- a chunked `vibe grep` sweep answers exactly
# what an unchunked one does (#2914).
#
# The typed tier could not finish a tree-wide sweep at all: a single wasm32
# process tops out at 4 GiB and the sweep's cost ACCUMULATES across files.
# `scripts/vibe_grep_bin.sh` now partitions the file list and runs each chunk
# in a FRESH process, which is the one thing that resets the frontier.
#
# THE PROPERTY WORTH GATING IS NOT "IT FINISHES". It is that the split does
# not change the answer. A chunked sweep that finishes while silently dropping
# matches at every chunk boundary would pass a "did it exit 0" check and be
# exactly the silent-wrong failure the design policy ranks above crashing. So
# this compares OUTPUT, byte for byte, across chunk sizes:
#
#   1. chunked == unchunked, for plain output.
#   2. chunked == unchunked, for JSON -- which is reassembled from one array
#      per chunk, so a boundary is where a trailing or doubled comma, or a
#      stray inner `[`, would appear.
#   3. two DIFFERENT chunk sizes agree with each other, so the answer does not
#      depend on where the boundaries fall.
#   4. a chunk size of 1 still agrees -- the degenerate split, one process per
#      file, where every boundary is exercised.
#
# A corpus is chosen that produces matches in SEVERAL files: with matches in
# one file, or none, every property above holds vacuously however broken the
# stitching is.
#
# WHICH COMPILER: the strict resolver. The chunk path needs a compiler that
# understands `VIBE_GREP_LIST_FILES`; an older one makes the driver fall back
# to the single-process call, and then this gate would compare that path
# against itself and pass while testing nothing. `VIBE_STAGE2_WASM` is the
# second name because the compiler-gate selftests lane exports it.
#
#   GREP_CHUNK_STAGE2=<stage2.wasm> bash scripts/check_grep_chunked_sweep.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

STAGE2="$(resolve_stage2_strict grep-chunked-sweep "${GREP_CHUNK_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1

CORPUS="${GREP_CHUNK_CORPUS:-lib/@vibe/core}"
PATTERN='Array::length($(x:exp))'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "grep-chunked-sweep: FAIL: $*" >&2
  exit 1
}

run_sweep() { # <chunk-or-empty> <json:0|1> <stdout-file>
  local chunk="$1" json="$2" out="$3" status=0 cache extra=()
  cache="$(mktemp -d)"
  [ -n "$chunk" ] && extra+=("VIBE_GREP_CHUNK_FILES=$chunk")
  [ "$json" = "1" ] && set -- --json || set --
  env VIBE_CLI_WASM="$STAGE2" VIBE_BUILD_CACHE_DIR="$cache" "${extra[@]}" \
      bash "$ROOT_DIR/scripts/vibe_grep_bin.sh" grep "$@" \
      --pattern "$PATTERN" "$CORPUS" >"$out" 2>"$out.err" || status=$?
  rm -rf "$cache"
  printf '%s' "$status"
}

# ---------------------------------------------------------------- the corpus
# Establish the baseline AND that it is non-vacuous, before anything is
# compared against it.
status="$(run_sweep "" 0 "$WORK/plain_unchunked")"
[ "$status" = "0" ] || fail "unchunked sweep failed (exit $status)
$(cat "$WORK/plain_unchunked.err")"
matches="$(grep -c . "$WORK/plain_unchunked" || true)"
[ "$matches" -ge 2 ] || fail "corpus '$CORPUS' produced $matches match(es).
Every comparison below holds vacuously on a corpus with fewer than 2 matches,
so this gate would pass while proving nothing about the stitching."
files="$(cut -d: -f1 < "$WORK/plain_unchunked" | sort -u | grep -c . || true)"
[ "$files" -ge 2 ] || fail "corpus '$CORPUS' has matches in $files file(s).
A chunk boundary can only be crossed when matches live in several files."
echo "grep-chunked-sweep: baseline $matches match(es) across $files file(s)"

# ------------------------------------------------------- properties 1 and 3
for chunk in 2 3; do
  status="$(run_sweep "$chunk" 0 "$WORK/plain_$chunk")"
  [ "$status" = "0" ] || fail "chunk=$chunk sweep failed (exit $status)
$(cat "$WORK/plain_$chunk.err")"
  cmp -s "$WORK/plain_unchunked" "$WORK/plain_$chunk" ||
    fail "chunk=$chunk changed the answer.
The split must not be visible in the result. First difference:
$(diff "$WORK/plain_unchunked" "$WORK/plain_$chunk" | head -5)"
done
cmp -s "$WORK/plain_2" "$WORK/plain_3" ||
  fail "chunk=2 and chunk=3 disagree, so the answer depends on where the
boundaries fall."
echo "grep-chunked-sweep: chunk=2 and chunk=3 both match the unchunked answer"

# ---------------------------------------------------------------- property 4
status="$(run_sweep 1 0 "$WORK/plain_1")"
[ "$status" = "0" ] || fail "chunk=1 sweep failed (exit $status)
$(cat "$WORK/plain_1.err")"
cmp -s "$WORK/plain_unchunked" "$WORK/plain_1" ||
  fail "chunk=1 -- one process per file, every boundary exercised -- changed
the answer.
$(diff "$WORK/plain_unchunked" "$WORK/plain_1" | head -5)"
echo "grep-chunked-sweep: chunk=1 (one process per file) matches"

# ---------------------------------------------------------------- property 2
status="$(run_sweep "" 1 "$WORK/json_unchunked")"
[ "$status" = "0" ] || fail "unchunked JSON sweep failed (exit $status)
$(cat "$WORK/json_unchunked.err")"
status="$(run_sweep 2 1 "$WORK/json_2")"
[ "$status" = "0" ] || fail "chunk=2 JSON sweep failed (exit $status)
$(cat "$WORK/json_2.err")"
cmp -s "$WORK/json_unchunked" "$WORK/json_2" ||
  fail "chunked JSON differs from unchunked JSON. A chunk boundary is exactly
where a doubled comma, a trailing comma or a stray inner bracket appears.
$(diff "$WORK/json_unchunked" "$WORK/json_2" | head -8)"
# One array for the whole sweep, whatever it was split into.
[ "$(head -c 1 "$WORK/json_2")" = "[" ] ||
  fail "chunked JSON does not start with '['"
[ "$(grep -c '^\[$' "$WORK/json_2" || true)" = "1" ] ||
  fail "chunked JSON has more than one opening bracket: the chunking leaked
into the answer as several arrays."
# ABSOLUTE, not relative. Everything above compares chunked against unchunked,
# which by construction cannot catch a defect that breaks BOTH paths the same
# way -- and they share the stitching code, so that is not a hypothetical: a
# mutation that emptied the final emit made both sides agree on nothing, and
# an earlier version of this gate passed it. The object count is checked
# against the PLAIN sweep instead, which does not go through the JSON path.
json_objects="$(grep -c '^ *{' "$WORK/json_2" || true)"
[ "$json_objects" = "$matches" ] ||
  fail "chunked JSON holds $json_objects object(s) but the plain sweep found
$matches match(es). The two disagree, so at least one of them is losing
results -- and comparing chunked against unchunked cannot tell which."
echo "grep-chunked-sweep: JSON is one array and matches the unchunked answer"

echo "grep-chunked-sweep: ok"

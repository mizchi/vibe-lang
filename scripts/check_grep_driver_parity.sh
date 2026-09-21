#!/usr/bin/env bash
# check_grep_driver_parity.sh -- the two `vibe grep` drivers answer alike
# (#2914).
#
# There are two of them and there have to be. `runtime/vibe` is a SELF-CONTAINED
# launcher: it sources nothing, because it installs standalone into ~/.vibe with
# no scripts/ beside it. `scripts/vibe_grep_bin.sh` exists for a checkout with no
# native runner (the SessionStart hook's VIBE_REVIEW_LINT_GREP_BIN). So the
# chunked-sweep loop is written twice, against two different CLI entry points --
# argv mode (`selfhost_cli_user_grep_args`) and env mode (`cli_adapter`) -- and a
# shared shell library is not available to prevent that.
#
# Duplication that nothing checks drifts. It already did once inside ONE file:
# two call sites in cli_adapter.vibe left `VIBE_GREP_RESUME` honoured on one and
# silently ignored on the other, which no gate saw until a mutation turned the
# flag on and nothing moved. Two files in two languages will drift faster. So
# the property gated here is not "each driver works" -- their own gates say that
# -- it is that they RETURN THE SAME ANSWER.
#
# Properties:
#   1. Unchunked, the two drivers agree byte for byte.
#   2. Chunked (2, and the degenerate 1), each agrees with the unchunked
#      baseline -- so the split is invisible on BOTH paths.
#   3. JSON agrees, and the object count matches the PLAIN sweep's match count.
#      Absolute, not relative: the two drivers share the stitching design, so
#      comparing them against each other cannot catch a defect that breaks both
#      the same way. That hole was real in check_grep_chunked_sweep.sh.
#   4. THE LOOP IS REAL. Everything above passes just as well if `runtime/vibe`
#      silently fell back to the single call -- which is exactly what it does
#      against a compiler that predates #2914. Proven by the discriminator the
#      budget gate uses: at a small budget the looping driver still answers,
#      while the same query with NO loop (the compiler invoked directly) refuses
#      with the budget diagnostic. Without this pair the gate is decorative.
#
# WHICH COMPILER: the strict resolver. This gate tests behaviour that exists
# only in a compiler built after #2914; resolve_stage2's degradation to the
# committed seed would make both drivers fall back, agree perfectly, and certify
# nothing.
#
#   GREP_PARITY_STAGE2=<stage2.wasm> bash scripts/check_grep_driver_parity.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
. "$ROOT_DIR/scripts/resolve_stage2.sh"

STAGE2="$(resolve_stage2_strict grep-driver-parity "${GREP_PARITY_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1

fail() {
  echo "grep-driver-parity: FAIL: $*" >&2
  exit 1
}

# `runtime/vibe` needs a native runner. Refused rather than skipped: a gate that
# quietly does nothing when a dependency is missing is indistinguishable from a
# passing one, and that is the failure this whole family exists for (#2580).
RUNNER="${VIBE_RUNNER:-$ROOT_DIR/runtime/viberun/target/release/viberun}"
[ -x "$RUNNER" ] ||
  fail "no viberun at $RUNNER.
This gate drives runtime/vibe, which cannot run without one. Build it with
scripts/ensure_viberun.sh, or point VIBE_RUNNER at one."

# The launcher under test. Overridable ONLY so the self-test can point this at
# a MUTATED COPY rather than editing `runtime/vibe` in place: that file is the
# repo's own launcher, exported by the SessionStart hook and used by other
# tooling, and an in-place mutation is live for as long as the gate runs. The
# first version of the self-test did edit it in place, and one interrupted run
# left `runtime/vibe` a zero-byte file -- recovered from the self-test's own
# backup, which is not a recovery path anything guarantees. The copy must sit
# in runtime/ so `$SELF` resolves the same way.
LAUNCHER="${GREP_PARITY_LAUNCHER:-$ROOT_DIR/runtime/vibe}"

# Four files, and every one of them matches -- chosen so the gate can afford to
# run nine sweeps (two drivers x four shapes, plus the control) and still be one
# of the companions check_gate_self_tests.sh runs SERIALLY on every invocation.
# It is also small enough for chunk=1, the degenerate split where every boundary
# is exercised. What it is NOT is cheap to type: measured on this corpus, the
# no-loop control refuses at 400 MB and succeeds at 1200 MB, which is what makes
# property 4 below a real discriminator rather than a formality.
CORPUS="${GREP_PARITY_CORPUS:-lib/@vibe/compiler/loader}"
PATTERN='Array::length($(x:exp))'
WHERE='$x : Array[String]'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Each run gets its own persistent cache: a warm cache changes how much a file
# allocates, which would make the budget in property 4 mean different things on
# the two sides (#2393).
run_launcher() { # <chunk-or-empty> <budget-or-empty> <json:0|1> <stdout>
  local chunk="$1" budget="$2" json="$3" out="$4" status=0 cache extra=()
  cache="$(mktemp -d)"
  [ -n "$chunk" ] && extra+=("VIBE_GREP_CHUNK_FILES=$chunk")
  [ -n "$budget" ] && extra+=("VIBE_GREP_MEMORY_BUDGET_MB=$budget")
  [ "$json" = "1" ] && set -- --json || set --
  env VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$RUNNER" VIBE_BUILD_CACHE_DIR="$cache" "${extra[@]}" \
      "$LAUNCHER" grep "$@" \
      --pattern "$PATTERN" --where "$WHERE" "$CORPUS" >"$out" 2>"$out.err" || status=$?
  rm -rf "$cache"
  printf '%s' "$status"
}

run_bin() { # <chunk-or-empty> <json:0|1> <stdout>
  local chunk="$1" json="$2" out="$3" status=0 cache extra=()
  cache="$(mktemp -d)"
  [ -n "$chunk" ] && extra+=("VIBE_GREP_CHUNK_FILES=$chunk")
  [ "$json" = "1" ] && set -- --json || set --
  env VIBE_CLI_WASM="$STAGE2" VIBE_BUILD_CACHE_DIR="$cache" "${extra[@]}" \
      bash "$ROOT_DIR/scripts/vibe_grep_bin.sh" grep "$@" \
      --pattern "$PATTERN" --where "$WHERE" "$CORPUS" >"$out" 2>"$out.err" || status=$?
  rm -rf "$cache"
  printf '%s' "$status"
}

# ---------------------------------------------------------------- the corpus
status="$(run_bin "" 0 "$WORK/bin_plain")"
[ "$status" = "0" ] || fail "the env-mode driver failed (exit $status)
$(cat "$WORK/bin_plain.err")"
matches="$(grep -c . "$WORK/bin_plain" || true)"
[ "$matches" -ge 2 ] || fail "corpus '$CORPUS' produced $matches match(es).
Every comparison below holds vacuously on a corpus with fewer than 2 matches."
files="$(cut -d: -f1 < "$WORK/bin_plain" | sort -u | grep -c . || true)"
[ "$files" -ge 2 ] || fail "corpus '$CORPUS' has matches in $files file(s).
A chunk boundary can only be crossed when matches live in several files."
echo "grep-driver-parity: baseline $matches match(es) across $files file(s)"

# ---------------------------------------------------------------- property 1
status="$(run_launcher "" "" 0 "$WORK/vibe_plain")"
[ "$status" = "0" ] || fail "runtime/vibe grep failed (exit $status)
$(cat "$WORK/vibe_plain.err")"
cmp -s "$WORK/bin_plain" "$WORK/vibe_plain" ||
  fail "the two drivers disagree on the same query.
runtime/vibe and scripts/vibe_grep_bin.sh drive different CLI entry points
(argv mode and env mode). One answer, two spellings -- that is the contract.
$(diff "$WORK/bin_plain" "$WORK/vibe_plain" | head -8)"
echo "grep-driver-parity: unchunked, both drivers answer identically"

# ---------------------------------------------------------------- property 2
for chunk in 2 1; do
  status="$(run_launcher "$chunk" "" 0 "$WORK/vibe_$chunk")"
  [ "$status" = "0" ] || fail "runtime/vibe at chunk=$chunk failed (exit $status)
$(cat "$WORK/vibe_$chunk.err")"
  cmp -s "$WORK/bin_plain" "$WORK/vibe_$chunk" ||
    fail "runtime/vibe at chunk=$chunk changed the answer.
$(diff "$WORK/bin_plain" "$WORK/vibe_$chunk" | head -8)"
  status="$(run_bin "$chunk" 0 "$WORK/bin_$chunk")"
  [ "$status" = "0" ] || fail "vibe_grep_bin.sh at chunk=$chunk failed (exit $status)
$(cat "$WORK/bin_$chunk.err")"
  cmp -s "$WORK/bin_plain" "$WORK/bin_$chunk" ||
    fail "vibe_grep_bin.sh at chunk=$chunk changed the answer.
$(diff "$WORK/bin_plain" "$WORK/bin_$chunk" | head -8)"
done
echo "grep-driver-parity: chunk=2 and chunk=1 match the baseline on both drivers"

# ---------------------------------------------------------------- property 3
status="$(run_launcher 2 "" 1 "$WORK/vibe_json")"
[ "$status" = "0" ] || fail "runtime/vibe JSON at chunk=2 failed (exit $status)
$(cat "$WORK/vibe_json.err")"
status="$(run_bin 2 1 "$WORK/bin_json")"
[ "$status" = "0" ] || fail "vibe_grep_bin.sh JSON at chunk=2 failed (exit $status)
$(cat "$WORK/bin_json.err")"
cmp -s "$WORK/bin_json" "$WORK/vibe_json" ||
  fail "the two drivers disagree in JSON. A chunk boundary is exactly where a
doubled comma, a trailing comma or a stray inner bracket appears, and each
driver reassembles the array itself.
$(diff "$WORK/bin_json" "$WORK/vibe_json" | head -8)"
[ "$(grep -c '^\[$' "$WORK/vibe_json" || true)" = "1" ] ||
  fail "runtime/vibe's chunked JSON has more than one opening bracket: the
chunking leaked into the answer as several arrays."
# ABSOLUTE. The two drivers share a design, so comparing them cannot catch a
# defect that breaks both the same way -- and an earlier version of the
# chunked-sweep gate passed exactly such a mutation. Counted against the PLAIN
# sweep, which does not go through the JSON path.
json_objects="$(grep -c '^ *{' "$WORK/vibe_json" || true)"
[ "$json_objects" = "$matches" ] ||
  fail "runtime/vibe's chunked JSON holds $json_objects object(s) but the plain
sweep found $matches match(es). At least one of them is losing results, and
comparing the two drivers cannot tell which."
echo "grep-driver-parity: JSON agrees and holds $json_objects object(s)"

# ---------------------------------------------------------------- property 4
# Everything above is satisfied by a runtime/vibe that never looped at all: the
# driver falls back to the single call against a compiler that does not
# understand `grep --list-files`, and a fallback agrees with the env-mode
# driver perfectly. So the loop is proven directly, by the one behaviour only a
# loop can produce -- answering at a budget a single process cannot finish
# under.
#
# The control is the SAME query with no loop around it: the compiler invoked
# through the runner directly, the way runtime/vibe's `invoke_cli grep` used to.
control_cache="$(mktemp -d)"
control_status=0
( cd "$ROOT_DIR" && env VIBE_GREP_MEMORY_BUDGET_MB=400 VIBE_BUILD_CACHE_DIR="$control_cache" \
    "$RUNNER" "$STAGE2" grep --pattern "$PATTERN" --where "$WHERE" "$CORPUS" ) \
  >"$WORK/control.out" 2>"$WORK/control.err" || control_status=$?
rm -rf "$control_cache"
[ "$control_status" != "0" ] ||
  fail "the no-loop control SUCCEEDED at a 400 MB budget, so that budget does
not force a hand-off on this corpus and property 4 proves nothing about the
loop. Lower GREP_PARITY_BUDGET or pick a larger corpus."
grep -q 'out of memory budget before typing' "$WORK/control.err" ||
  fail "the no-loop control failed at a 400 MB budget, but not with the budget
diagnostic -- so it stopped for some other reason and is not a control.
$(head -5 "$WORK/control.err")"

status="$(run_launcher "" 400 0 "$WORK/vibe_budget")"
[ "$status" = "0" ] || fail "runtime/vibe did NOT survive a 400 MB budget that
the no-loop control refuses (exit $status). The resume loop is not running --
either it fell back to the single call, or the hand-off is not being honoured.
$(cat "$WORK/vibe_budget.err")"
cmp -s "$WORK/bin_plain" "$WORK/vibe_budget" ||
  fail "runtime/vibe answered at a 400 MB budget, but not with the same answer.
A hand-off that dropped the files around each boundary would still exit 0,
which is why this compares OUTPUT and not just the status.
$(diff "$WORK/bin_plain" "$WORK/vibe_budget" | head -8)"
echo "grep-driver-parity: runtime/vibe answers at a budget the no-loop control refuses"

# ---------------------------------------------------------------- property 5
# THE ADVERTISED FLAGS REACH THE CLI. `grep --help` documents `--list-files`,
# `--file-list` and `--resume-out` for a caller partitioning a sweep itself,
# and the launcher wraps its own loop around every grep call -- so using them
# as documented put them AFTER the loop's own copies, where the guest's parser
# takes the last occurrence. A caller's `--resume-out` won, the loop's file was
# never written, and that reads as "no hand-off": advance by the whole slice
# and exit 0, having skipped every file the sweep did not reach (Codex on
# #2956, P2). The loop now stands aside for these flags.
#
# `--where` IS LOAD-BEARING TOO, and leaving it out made this case certify
# nothing for the SECOND time. `grep_sweep` short-circuits to a direct call
# twice: once for the driver flags this property is about, and once for an
# untyped sweep, which cannot hand off and so gains nothing from the loop. An
# untyped probe is caught by the second bypass even when the mutation removes
# the first, so the banner count stayed 1 and the mutation passed. Both times
# the cause was the same shape -- something else short-circuits before the
# property can be observed -- and both times only the mutation showed it.
#
# VIBE_GREP_CHUNK_FILES=1 IS LOAD-BEARING, and leaving it out made this case
# certify nothing the first time. The corpus is 4 files and the default cap is 8, so the sweep
# takes ONE chunk -- and "each chunk re-answers the listing" cannot be seen
# when there is only one chunk. Measured: with the bypass removed the banner
# count stayed 1 and this property passed, which the self-test caught by the
# mutation failing to redden the gate. At cap=1 the same removal yields one
# listing per file instead.
listing_out="$WORK/listing"
status=0
env VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$RUNNER" VIBE_BUILD_CACHE_DIR="$WORK/cache_listing" \
    VIBE_GREP_CHUNK_FILES=1 \
    "$LAUNCHER" grep --list-files --pattern "$PATTERN" --where "$WHERE" "$CORPUS" \
    >"$listing_out" 2>"$listing_out.err" || status=$?
[ "$status" = "0" ] || fail "runtime/vibe grep --list-files failed (exit $status)
$(cat "$listing_out.err")"
banners="$(grep -c '^vibe-grep-file-list-v1$' "$listing_out" || true)"
[ "$banners" = "1" ] ||
  fail "--list-files printed $banners banner(s), want exactly 1.
More than one means the loop ran anyway and each chunk re-answered the listing;
zero means the flag did not reach the CLI at all."
grep -qE '^[^:]+\.vibe$' "$listing_out" ||
  fail "--list-files printed no file paths.
$(head -3 "$listing_out")"
grep -qE ':[0-9]+:[0-9]+:' "$listing_out" &&
  fail "--list-files printed MATCH lines, so it swept instead of listing --
which is exactly the shape the banner probe exists to tell apart."
echo "grep-driver-parity: --list-files answers once and lists files, not matches"

# `--file-list` likewise: the caller's list is what gets swept, not a
# re-derived one. One file in, matches from that file only.
one_list="$WORK/one_file_list"
head -2 "$listing_out" | tail -1 > "$one_list"
one_file="$(cat "$one_list")"
[ -n "$one_file" ] || fail "could not take a single file from the listing"
status=0
env VIBE_CLI_WASM="$STAGE2" VIBE_RUNNER="$RUNNER" VIBE_BUILD_CACHE_DIR="$WORK/cache_filelist" \
    "$LAUNCHER" grep --file-list "$one_list" --pattern "$PATTERN" --where "$WHERE" "$CORPUS" \
    >"$WORK/one.out" 2>"$WORK/one.err" || status=$?
[ "$status" = "0" ] || fail "runtime/vibe grep --file-list failed (exit $status)
$(cat "$WORK/one.err")"
stray="$(cut -d: -f1 < "$WORK/one.out" | sort -u | grep -vxF "$one_file" | head -3 || true)"
[ -z "$stray" ] ||
  fail "--file-list named one file but the sweep covered others:
$stray
The caller's list was ignored or re-chunked."
echo "grep-driver-parity: --file-list sweeps exactly the caller's list"

echo "grep-driver-parity: ok"

#!/usr/bin/env bash
# An opt-in observation must never destroy what it observes (#2510, #2735).
#
# `VIBE_INCREMENTAL_TELEMETRY_OUT` names a file the CLI DELETES before the
# compile (so a stale sidecar cannot be read as this run's result) and WRITES
# after it. Both are destructive, and neither is visible in the source of the
# function that performs them: the delete sits in the shared request block near
# the top of cli_main and the write sits ~600 lines below it. Five review
# rounds on #2735 each found one more path where the pair was ordered wrongly,
# so the property is asked of the running compiler here rather than read off
# the source.
#
# Measured against the build that carried the guard as first reviewed
# (9674b06), which compared raw spellings and only against the artifact:
#
#   telemetry path      | there                          | here
#   --------------------+--------------------------------+-----------------
#   = the input source  | exit 1, SOURCE DELETED         | refused, intact
#   = build/./out.wasm  | exit 0, WASM REPLACED BY JSON  | refused, intact
#   = a directory       | exit 0, TREE DELETED           | refused, intact
#   = the trace sidecar | exit 0, TRACE REPLACED         | refused
#
# And against the build that carried the identity check but not the symlink or
# derived-path rows (e88ab7b):
#
#   telemetry path      | there                          | here
#   --------------------+--------------------------------+-----------------
#   = a symlinked entry | exit 1, REAL SOURCE DELETED    | refused, intact
#     entry's target    |   and the entry left dangling  |
#   = <output>.diag     | exit 0, and runtime/vibe then  | refused
#                       |   deletes the sidecar it asked |
#                       |   this build to produce        |
#   = <output>.funcmap  | exit 0, BACKTRACE MAP REPLACED | refused
#
# And against the build that carried those rows but compared identity only for
# paths that EXIST (d836c22):
#
#   telemetry path           | there                     | here
#   -------------------------+---------------------------+----------
#   = build/./out.wasm.diag  | exit 0, and the canonical | refused
#     on a successful compile|   <output>.diag holds the |
#                            |   counters, for runtime/  |
#                            |   vibe to then delete     |
#
# The positive case is not decoration. A compiler that ignores the variable
# entirely destroys nothing and would pass every row above. Asserting that a plain request PUBLISHES a
# well-formed sidecar is what makes the refusals mean "refused" rather than
# "not implemented", and it is the assertion this gate's self-test trips.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

. "$(dirname "$0")/resolve_stage2.sh"
STAGE2="$(resolve_stage2 telemetry-sidecar-guards "${TELEMETRY_GUARD_STAGE2:-}")" || exit 1

WORK="$ROOT_DIR/_build/_telemetry_sidecar_guards"
rm -rf "$WORK"; mkdir -p "$WORK/build" "$WORK/cache"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/prog.vibe"
OUT="$WORK/build/out.wasm"
cat > "$SRC" <<'VIBE'
fn main() -> Unit {
  ()
}
VIBE
cp "$SRC" "$WORK/prog.vibe.orig"

fails=0
fail() { echo "[telemetry-sidecar-guards] FAIL: $*" >&2; fails=$((fails + 1)); }

# One compile. Prints the exit status so a caller can assert on it without
# tripping `set -e`.
#
# VIBE_RC=0 is pinned rather than left unset because the artifact-input trace
# admits a request only on that exact lane. Unset is not "0": with it unset the
# trace row below is refused for a LANE reason and the row passes without ever
# reaching the collision it exists to test -- measured, that is how it passed
# against the build this gate is supposed to reject.
compile() { # compile <telemetry-out> [trace-out]
  set +e
  env VIBE_FS_COMPILE=1 VIBE_RC=0 VIBE_BUILD_CACHE_DIR="$WORK/cache" \
      VIBE_INCREMENTAL_TELEMETRY_OUT="$1" \
      ${2:+VIBE_ARTIFACT_INPUT_TRACE_OUT="$2"} ${2:+VIBE_ARTIFACT_INPUT_TRACE_NONCE=guard} \
      bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
      "$STAGE2" "$SRC" "$OUT" main >"$WORK/run.log" 2>&1
  echo "$?"
  set -e
}

# --- positive: a plain request publishes a well-formed sidecar -------------
TELE="$WORK/tele.json"
status="$(compile "$TELE")"
if [ "$status" != "0" ]; then
  fail "a plain telemetry request did not compile (exit $status); see $WORK/run.log"
elif [ ! -f "$TELE" ]; then
  fail "a successful compile published no sidecar at $TELE"
elif ! grep -q '"modules_planned"' "$TELE"; then
  fail "the published sidecar has no modules_planned field: $(cat "$TELE")"
elif grep -q '"modules_planned":0' "$TELE"; then
  fail "the published sidecar planned no modules: $(cat "$TELE")"
fi
[ -s "$OUT" ] || fail "the positive case produced no artifact to alias in the rows below"

# --- refusals: each names something the run would otherwise destroy --------
# `$OUT` exists from the positive case, which is what lets the identity test
# see through the second spelling.
refuse() { # refuse <label> <telemetry-out> [trace-out]
  local label="$1" telemetry="$2" trace="${3:-}" status
  status="$(compile "$telemetry" "$trace")"
  [ "$status" != "0" ] || fail "$label: accepted (exit 0); see $WORK/run.log"
}

artifact_intact() { # artifact_intact <label>
  if [ ! -s "$OUT" ]; then
    fail "the artifact was destroyed ($1)"
  elif ! head -c 4 "$OUT" | grep -q 'asm'; then
    fail "the artifact was replaced ($1)"
  fi
}

# Put the fixture back between rows. A row that DOES destroy something would
# otherwise make every row after it pass VACUOUSLY -- the next compile fails
# because the source is missing, not because the request was refused.
# Measured, and the reason this exists: against 9674b06 the first row deletes
# the source, and the trace row three rows later then "passed".
restore() {
  cp "$WORK/prog.vibe.orig" "$SRC"
  if [ ! -s "$OUT" ] || ! head -c 4 "$OUT" | grep -q 'asm'; then
    rm -f "$OUT"
    if [ "$(compile "$WORK/rebuild.json")" != "0" ] || [ ! -s "$OUT" ]; then
      fail "could not rebuild the fixture artifact; later rows are not meaningful"
    fi
  fi
}

refuse "the input source" "$SRC"
cmp -s "$SRC" "$WORK/prog.vibe.orig" || fail "the input source was destroyed by a refused request"
restore

refuse "the artifact, same spelling" "$OUT"
artifact_intact "same spelling"
restore

refuse "the artifact, a second spelling" "$WORK/build/./out.wasm"
artifact_intact "second spelling"
restore

mkdir -p "$WORK/adir"; : > "$WORK/adir/keep"
refuse "a directory" "$WORK/adir"
[ -f "$WORK/adir/keep" ] || fail "a directory destination was cleared recursively"
restore

refuse "the artifact-input trace" "$WORK/both.json" "$WORK/both.json"
if grep -q '"modules_planned"' "$WORK/both.json" 2>/dev/null; then
  fail "the requested artifact-input trace was replaced by telemetry counters"
fi
restore

# `<output>.diag` and `<output>.funcmap` are derived and compiler-owned. The
# first is removed by runtime/vibe once it sees a non-empty artifact, so a
# sidecar published there is deleted by the build that was asked for it; the
# second annotates runtime backtraces.
refuse "the derived .diag sidecar" "$OUT.diag"
# `<output>.diag` is the one derived path a SUCCESSFUL compile never writes, so
# the identity test has nothing to stat and a second spelling of it reached the
# publication. Clear it first, so this row runs in exactly that state.
rm -f "$OUT.diag"
refuse "the derived .diag sidecar, a second spelling" "$WORK/build/./out.wasm.diag"
grep -q '"modules_planned"' "$OUT.diag" 2>/dev/null &&
  fail "telemetry landed on the canonical <output>.diag"
refuse "the derived .funcmap sidecar" "$OUT.funcmap"
[ -s "$OUT.funcmap" ] || fail "the compile left no .funcmap, so that row proves nothing"
grep -q '"modules_planned"' "$OUT.funcmap" 2>/dev/null &&
  fail "the backtrace map holds telemetry JSON"
restore

# The ENTRY reached through a symlink, with the destination naming its target.
# The identity check cannot resolve a link, so "different tokens" would read as
# "different files" here -- measured, that deleted the real source and left the
# entry dangling.
mkdir -p "$WORK/link"
cp "$WORK/prog.vibe.orig" "$WORK/link/real.vibe"
ln -sf real.vibe "$WORK/link/entry.vibe"
set +e
env VIBE_FS_COMPILE=1 VIBE_RC=0 VIBE_BUILD_CACHE_DIR="$WORK/cache" \
    VIBE_INCREMENTAL_TELEMETRY_OUT="$WORK/link/real.vibe" \
    bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main \
    "$STAGE2" "$WORK/link/entry.vibe" "$WORK/build/link.wasm" main >"$WORK/run.log" 2>&1
link_status=$?
set -e
[ "$link_status" != "0" ] || fail "a symlinked entry aliasing its target: accepted (exit 0)"
[ -f "$WORK/link/real.vibe" ] || fail "the real source behind a symlinked entry was deleted"
[ -e "$WORK/link/entry.vibe" ] || fail "the symlinked entry was left dangling"

# The artifact is absent here, so neither path exists when the early refusal
# runs and only the one at the publication boundary can see the alias.
rm -f "$OUT"
refuse "the artifact before it exists" "$WORK/build/./out.wasm"
if [ -f "$OUT" ] && grep -q '"modules_planned"' "$OUT" 2>/dev/null; then
  fail "the artifact path holds telemetry JSON"
fi

if [ "$fails" -ne 0 ]; then
  echo "[telemetry-sidecar-guards] $fails check(s) failed" >&2
  exit 1
fi
echo "[telemetry-sidecar-guards] ok"

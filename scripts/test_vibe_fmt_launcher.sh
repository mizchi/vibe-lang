#!/usr/bin/env bash
# `vibe fmt` as an installed user reaches it (#2149, #2858).
#
# Since #2858 the formatter's decisions -- mode dispatch, the two refusals,
# one file at a time -- live in lib/@vibe/compiler/user_dispatch.vibe, and
# runtime/vibe only forwards the verb. So this drives the REAL compiler (the
# stage2 named by VIBE_CLI_WASM, else the newest generation, else the seed)
# and pins what the user sees on each path. The launcher decisions that are
# left -- clearing inherited adapter-mode selectors before the runner starts,
# and never reading a dead runner as a clean format -- are checked here too,
# the second with a fake runner because only a fake can die on cue.
#
# The refusal that matters (#1821): a formatted output the parser rejects, or
# an input that does not parse, must never be reported as "formatted" and must
# leave the file alone in every mode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=resolve_stage2.sh
. "$ROOT_DIR/scripts/resolve_stage2.sh"
CLI="$(resolve_stage2 vibe-fmt-launcher "${VIBE_CLI_WASM:-}")"
RUNNER="${VIBE_RUNNER:-}"
if [ -z "$RUNNER" ]; then
  RUNNER="$ROOT_DIR/runtime/viberun/target/release/viberun"
  [ -x "$RUNNER" ] || RUNNER="$ROOT_DIR/scripts/viberun_node.sh"
fi

# Under the checkout so the node runner's preopen covers it.
WORK="$ROOT_DIR/_build/_gate_fmt_launcher"
rm -rf "$WORK"; mkdir -p "$WORK"
cleanup() {
  local status=$?
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

SRC="$WORK/in.vibe"
OUT="$WORK/stdout.txt"
ERR="$WORK/stderr.txt"

fail() {
  echo "[vibe-fmt-launcher] FAIL: $1" >&2
  [ -s "$OUT" ] && { echo "--- stdout"; cat "$OUT"; } >&2
  [ -s "$ERR" ] && { echo "--- stderr"; cat "$ERR"; } >&2
  exit 1
}
vfmt() { # <args...>; runs the launcher's fmt against the real compiler
  VIBE_RUNNER="$RUNNER" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" "$@" > "$OUT" 2> "$ERR"
}

# --stdout prints the formatted result and leaves the file alone.
printf 'let   a=1\n' > "$SRC"
vfmt fmt --stdout "$SRC" || fail "--stdout exited non-zero"
[ "$(cat "$OUT")" = "let a = 1" ] || fail "--stdout did not print the formatted result"
[ "$(cat "$SRC")" = "let   a=1" ] || fail "--stdout rewrote the source file"

# --check exits 1 on an unformatted file and NAMES it, 0 on a formatted one.
if vfmt fmt --check "$SRC"; then
  fail "--check reported an unformatted file as formatted"
fi
cat "$OUT" "$ERR" | grep -q "not formatted" || fail "--check did not name the unformatted file"
printf 'let a = 1\n' > "$SRC"
vfmt fmt --check "$SRC" || fail "--check rejected an already-formatted file"
[ ! -s "$OUT" ] || fail "--check on a formatted file printed something"

# Write mode rewrites in place, and is a no-op on a formatted file.
printf 'let   a=1\n' > "$SRC"
vfmt fmt "$SRC" || fail "write mode exited non-zero"
[ "$(cat "$SRC")" = "let a = 1" ] || fail "write mode did not rewrite the file"

# THE PARSE REFUSAL (#2636, Codex on #2708). An input that does not parse is
# refused with the parse error and the edit to make, NOT the "bug in the
# formatter" text of the other refusal, and the file is untouched in every
# mode.
printf 'let a=x?1:2\n' > "$SRC"
for mode in "" "--check" "--stdout"; do
  # shellcheck disable=SC2086
  if vfmt fmt $mode "$SRC"; then
    fail "an input that does not parse was formatted (exit 0) in mode '${mode:-write}'"
  fi
  grep -q "does not parse" "$ERR" || fail "an input that does not parse was not reported as such in mode '${mode:-write}'"
  grep -q "unexpected token" "$ERR" || fail "the parse error did not reach the user in mode '${mode:-write}'"
  if grep -q "bug in" "$ERR"; then
    fail "an input that does not parse was reported as a formatter bug in mode '${mode:-write}'"
  fi
  [ ! -s "$OUT" ] || fail "a refused format printed to stdout in mode '${mode:-write}'"
done
[ "$(cat "$SRC")" = "let a=x?1:2" ] || fail "an input that does not parse was rewritten"

# A runner that dies underneath the CLI must not be reported as a clean
# format, and must not touch the file. Only a fake can die on cue.
DEAD_RUNNER="$WORK/dead-runner"
printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$DEAD_RUNNER"
chmod +x "$DEAD_RUNNER"
printf 'let   a=1\n' > "$SRC"
if VIBE_RUNNER="$DEAD_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"; then
  fail "a runner that died was reported as a clean format"
fi
grep -q "runner failed" "$ERR" || fail "a runner that died was not reported as such"
[ "$(cat "$SRC")" = "let   a=1" ] || fail "a runner that died still rewrote the source"

# Adapter-mode selectors inherited from the environment must be cleared
# before the runner starts (ADAPTER_MODE_CLEARS). cli_adapter evaluates
# VIBE_HASH before VIBE_FMT, so a leaked selector used to write a HASH as the
# artifact -- and write mode copied it over the user's source file. Every
# selector, not just the two the first draft named: a loop over eight
# variables against an arm that clears two is a test that cannot fail for
# the other six (it didn't: removing `-u VIBE_CHECK_ONLY` left this green).
for leak in VIBE_HASH VIBE_NORMALIZE VIBE_CHECK_ONLY VIBE_LSP VIBE_MODULE_JOB_DIR \
            VIBE_PUBLISH_ENV_CACHE VIBE_LIST_DEPS VIBE_MODULE_PLAN; do
  printf 'let   a=1\n' > "$SRC"
  env "$leak=1" VIBE_RUNNER="$RUNNER" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
    bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR" \
    || fail "inherited $leak made vibe fmt fail"
  [ "$(cat "$SRC")" = "let a = 1" ] || fail "inherited $leak diverted vibe fmt and overwrote the source"
done

# The reverse direction: VIBE_FMT inherited by `vibe normalize` must not
# preempt it -- the fmt branch is evaluated FIRST in cli_adapter, so without
# a clear the command would format and report success without normalizing.
printf 'let   a=1\n' > "$SRC"
vfmt normalize --stdout "$SRC" || fail "vibe normalize --stdout failed"
cp "$OUT" "$WORK/normalized.txt"
env VIBE_FMT=1 VIBE_RUNNER="$RUNNER" VIBE_CLI_WASM="$CLI" VIBE_PREOPEN_DIR="$ROOT_DIR" \
  bash "$ROOT_DIR/runtime/vibe" normalize --stdout "$SRC" > "$OUT" 2> "$ERR" \
  || fail "inherited VIBE_FMT made vibe normalize fail"
cmp -s "$OUT" "$WORK/normalized.txt" || fail "inherited VIBE_FMT changed what vibe normalize printed"
[ "$(cat "$SRC")" = "let   a=1" ] || fail "vibe normalize --stdout rewrote the source"

# An EMPTY file is a legitimate, already-formatted file. Testing output SIZE
# used to reject it with "fmt failed".
: > "$SRC"
vfmt fmt --check "$SRC" || fail "an empty file that is already formatted was reported as a failure"

# More than one path must be REJECTED, not silently half-done. Formatting the
# first and exiting 0 is how an unformatted file reached CI in #2156.
printf 'let   a=1\n' > "$SRC"
SRC2="$WORK/in2.vibe"
printf 'let   b=2\n' > "$SRC2"
if vfmt fmt "$SRC" "$SRC2"; then
  fail "two source paths were accepted and only one was formatted"
fi
[ "$(cat "$SRC")" = "let   a=1" ] || fail "the first path was rewritten by a call that should have been rejected"
[ "$(cat "$SRC2")" = "let   b=2" ] || fail "the second path was rewritten by a call that should have been rejected"

echo "[vibe-fmt-launcher] ok"

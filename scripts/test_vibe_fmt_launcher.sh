#!/usr/bin/env bash
# `vibe fmt` launcher arm (#2149). Drives runtime/vibe with a FAKE runner, so
# this pins the shell arm's own decisions -- mode dispatch, the refusal path,
# and adapter-mode env clearing -- without a compiler build.
#
# The refusal case is the one that matters. On refusal the adapter writes the
# INPUT back to $out and returns non-zero, so $out is non-empty and identical
# to the source. A `--check` that looked only at `cmp` would call that
# "formatted" -- which is exactly how a declining formatter came to look like
# one with nothing to change (#1821). The arm must read the runner's last
# stdout line instead.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe-fmt-launcher.XXXXXX")"
cleanup() {
  local status=$?
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

SRC="$TMP_DIR/in.vibe"
CLI="$TMP_DIR/vibe-cli.wasm"
OUT="$TMP_DIR/stdout.txt"
ERR="$TMP_DIR/stderr.txt"
: > "$CLI"

fail() {
  echo "[vibe-fmt-launcher] FAIL: $1" >&2
  [ -s "$ERR" ] && cat "$ERR" >&2
  exit 1
}

# A runner that "formats" by writing a fixed canonical text and returning 0.
OK_RUNNER="$TMP_DIR/ok-runner"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "let a = 1\n" > "$3"' \
  'echo 0' > "$OK_RUNNER"
chmod +x "$OK_RUNNER"

# --stdout prints the formatted result and leaves the file alone.
printf 'let   a=1\n' > "$SRC"
VIBE_RUNNER="$OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt --stdout "$SRC" > "$OUT" 2> "$ERR"
[ "$(cat "$OUT")" = "let a = 1" ] || fail "--stdout did not print the formatted result"
[ "$(cat "$SRC")" = "let   a=1" ] || fail "--stdout rewrote the source file"

# --check exits 1 on an unformatted file, 0 on a formatted one.
if VIBE_RUNNER="$OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt --check "$SRC" > "$OUT" 2> "$ERR"; then
  fail "--check reported an unformatted file as formatted"
fi
grep -q "not formatted" "$ERR" || fail "--check did not name the unformatted file"
printf 'let a = 1\n' > "$SRC"
VIBE_RUNNER="$OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt --check "$SRC" > "$OUT" 2> "$ERR" \
  || fail "--check rejected an already-formatted file"

# Write mode rewrites in place.
printf 'let   a=1\n' > "$SRC"
VIBE_RUNNER="$OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"
[ "$(cat "$SRC")" = "let a = 1" ] || fail "write mode did not rewrite the file"

# THE REFUSAL. The runner echoes the input back and reports 1, exactly as the
# adapter's guard does when the formatted output does not parse and the input
# did. $out is then byte-identical to the source, so `cmp` alone would say
# "formatted".
REFUSE_RUNNER="$TMP_DIR/refuse-runner"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'cat "$2" > "$3"' \
  'echo 1' > "$REFUSE_RUNNER"
chmod +x "$REFUSE_RUNNER"

printf 'let   a=1\n' > "$SRC"
for mode in "" "--check" "--stdout"; do
  # shellcheck disable=SC2086
  if VIBE_RUNNER="$REFUSE_RUNNER" VIBE_CLI_WASM="$CLI" \
    bash "$ROOT_DIR/runtime/vibe" fmt $mode "$SRC" > "$OUT" 2> "$ERR"; then
    fail "a refused format exited 0 in mode '${mode:-write}'"
  fi
  grep -q "refusing to rewrite" "$ERR" || fail "a refused format did not say so in mode '${mode:-write}'"
done
[ "$(cat "$SRC")" = "let   a=1" ] || fail "a refused format still rewrote the source file"

# A runner that produces no output must not be reported as a clean format.
EMPTY_RUNNER="$TMP_DIR/empty-runner"
printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$EMPTY_RUNNER"
chmod +x "$EMPTY_RUNNER"
if VIBE_RUNNER="$EMPTY_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"; then
  fail "a runner that wrote nothing was reported as a clean format"
fi

# Adapter-mode envs must be cleared. cli_adapter evaluates VIBE_HASH before
# VIBE_FMT, so a leaked selector would write a HASH as $out -- and write mode
# would then copy it over the user's source file.
# The fake runner must divert on EVERY selector under test, not just the two
# the first draft named -- a loop over eight variables against a runner that
# only knows two is a test that cannot fail for the other six. (It didn't:
# removing `-u VIBE_CHECK_ONLY` from the arm left this green.)
ENV_RUNNER="$TMP_DIR/env-runner"
cat > "$ENV_RUNNER" <<'RUNNER'
#!/usr/bin/env bash
for v in VIBE_HASH VIBE_NORMALIZE VIBE_CHECK_ONLY VIBE_LSP VIBE_MODULE_JOB_DIR \
         VIBE_PUBLISH_ENV_CACHE VIBE_LIST_DEPS VIBE_MODULE_PLAN; do
  if [ "${!v:-}" = "1" ]; then printf 'DIVERTED-%s\n' "$v" > "$3"; echo 0; exit 0; fi
done
printf 'let a = 1\n' > "$3"
echo 0
RUNNER
chmod +x "$ENV_RUNNER"
# EVERY selector cli_adapter evaluates before VIBE_FMT, not just the two the
# normalize arm's list happened to name. Measured on a real stage2: with
# VIBE_CHECK_ONLY=1 inherited, the check branch wrote "ok" to the output and
# write mode copied THAT over the source file.
for leak in VIBE_HASH VIBE_NORMALIZE VIBE_CHECK_ONLY VIBE_LSP VIBE_MODULE_JOB_DIR \
            VIBE_PUBLISH_ENV_CACHE VIBE_LIST_DEPS VIBE_MODULE_PLAN; do
  printf 'let   a=1\n' > "$SRC"
  env "$leak=1" VIBE_RUNNER="$ENV_RUNNER" VIBE_CLI_WASM="$CLI" \
    bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"
  [ "$(cat "$SRC")" = "let a = 1" ] || fail "inherited $leak diverted vibe fmt and overwrote the source"
done

# The reverse direction: VIBE_FMT inherited by `vibe normalize` must not
# preempt it. The fmt branch is evaluated FIRST in cli_adapter, so without a
# clear the command would format and report success without normalizing.
NORM_RUNNER="$TMP_DIR/norm-runner"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${VIBE_FMT:-}" = "1" ]; then printf "formatted\n" > "$3"; echo 0; exit 0; fi' \
  'printf "normalized\n" > "$3"' \
  'echo 0' > "$NORM_RUNNER"
chmod +x "$NORM_RUNNER"
printf 'let a = 1\n' > "$SRC"
VIBE_FMT=1 VIBE_RUNNER="$NORM_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" normalize "$SRC" > "$OUT" 2> "$ERR"
[ "$(cat "$SRC")" = "normalized" ] || fail "inherited VIBE_FMT preempted vibe normalize"

# An EMPTY result is legitimate -- an empty or whitespace-only file formats to
# an empty one. Testing output SIZE rejected those with "fmt failed".
EMPTY_OUT_RUNNER="$TMP_DIR/empty-out-runner"
printf '%s\n' '#!/usr/bin/env bash' ': > "$3"' 'echo 0' > "$EMPTY_OUT_RUNNER"
chmod +x "$EMPTY_OUT_RUNNER"
: > "$SRC"
VIBE_RUNNER="$EMPTY_OUT_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt --check "$SRC" > "$OUT" 2> "$ERR" \
  || fail "an empty file that is already formatted was reported as a failure"
printf 'x\n' > "$SRC"
VIBE_RUNNER="$EMPTY_OUT_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR" \
  || fail "an empty formatted result was reported as a failure"
[ ! -s "$SRC" ] || fail "an empty formatted result was not written"

# More than one path must be REJECTED, not silently half-done. Formatting the
# first and exiting 0 is how an unformatted file reached CI in #2156.
printf 'let   a=1\n' > "$SRC"
SRC2="$TMP_DIR/in2.vibe"
printf 'let   b=2\n' > "$SRC2"
if VIBE_RUNNER="$OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" "$SRC2" > "$OUT" 2> "$ERR"; then
  fail "two source paths were accepted and only one was formatted"
fi
[ "$(cat "$SRC2")" = "let   b=2" ] || fail "the second path was rewritten by a call that should have been rejected"

# THE OTHER RUNNER CONVENTION. Every fake above prints cli_main's return as the
# last stdout line, which is what the node runner does. The installed `viberun`
# running the shipped CLI prints NOTHING and turns that value into the process
# exit status instead (lib/@vibe/cli/main.vibex). Modelling only the printed
# path is how an arm that reports every successful format as "fmt failed" for
# installed users passed its own tests.
EXIT_OK_RUNNER="$TMP_DIR/exit-ok-runner"
printf '%s\n' '#!/usr/bin/env bash' 'printf "let a = 1\n" > "$3"' 'exit 0' > "$EXIT_OK_RUNNER"
chmod +x "$EXIT_OK_RUNNER"
printf 'let   a=1\n' > "$SRC"
VIBE_RUNNER="$EXIT_OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR" \
  || fail "a runner that reports success by EXIT STATUS was treated as a failure"
[ "$(cat "$SRC")" = "let a = 1" ] || fail "a status-only runner's successful format was not written"

VIBE_RUNNER="$EXIT_OK_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt --stdout "$SRC" > "$OUT" 2> "$ERR" \
  || fail "--stdout failed against a status-only runner"
[ "$(cat "$OUT")" = "let a = 1" ] || fail "--stdout printed nothing against a status-only runner"

# ...and a refusal signalled the same way: input echoed back, non-zero EXIT.
EXIT_REFUSE_RUNNER="$TMP_DIR/exit-refuse-runner"
printf '%s\n' '#!/usr/bin/env bash' 'cat "$2" > "$3"' 'exit 1' > "$EXIT_REFUSE_RUNNER"
chmod +x "$EXIT_REFUSE_RUNNER"
printf 'let   a=1\n' > "$SRC"
if VIBE_RUNNER="$EXIT_REFUSE_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"; then
  fail "a refusal signalled by exit status was reported as success"
fi
grep -q "refusing to rewrite" "$ERR" || fail "a status-signalled refusal did not say so"
[ "$(cat "$SRC")" = "let   a=1" ] || fail "a status-signalled refusal still rewrote the source"

echo "[vibe-fmt-launcher] ok"

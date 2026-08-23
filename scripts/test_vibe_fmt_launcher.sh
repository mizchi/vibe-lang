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
ENV_RUNNER="$TMP_DIR/env-runner"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${VIBE_HASH:-}" = "1" ]; then printf "deadbeef\n" > "$3"; echo 0; exit 0; fi' \
  'if [ "${VIBE_NORMALIZE:-}" = "1" ]; then printf "normalized\n" > "$3"; echo 0; exit 0; fi' \
  'printf "let a = 1\n" > "$3"' \
  'echo 0' > "$ENV_RUNNER"
chmod +x "$ENV_RUNNER"
for leak in VIBE_HASH VIBE_NORMALIZE; do
  printf 'let   a=1\n' > "$SRC"
  env "$leak=1" VIBE_RUNNER="$ENV_RUNNER" VIBE_CLI_WASM="$CLI" \
    bash "$ROOT_DIR/runtime/vibe" fmt "$SRC" > "$OUT" 2> "$ERR"
  [ "$(cat "$SRC")" = "let a = 1" ] || fail "inherited $leak diverted vibe fmt and overwrote the source"
done

echo "[vibe-fmt-launcher] ok"

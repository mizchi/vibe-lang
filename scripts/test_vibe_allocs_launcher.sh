#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe-allocs-launcher.XXXXXX")"
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

printf 'fn main() -> Array[Int] { [1] }\n' > "$SRC"
: > "$CLI"

# A runner crash without a .diag sidecar must not be indistinguishable from
# the allocation query's clean (empty output) result.
FAIL_RUNNER="$TMP_DIR/fail-runner"
printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$FAIL_RUNNER"
chmod +x "$FAIL_RUNNER"
if VIBE_RUNNER="$FAIL_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" allocs "$SRC" > "$OUT" 2> "$ERR"; then
  echo "[vibe-allocs-launcher] FAIL: runner exit 23 was reported as a clean query" >&2
  exit 1
fi
if ! grep -q 'runner failed with status 23' "$ERR"; then
  echo "[vibe-allocs-launcher] FAIL: runner failure did not explain its status" >&2
  cat "$ERR" >&2
  exit 1
fi

# Public subcommands must select their own adapter mode even when invoked from
# a shell that inherited an internal compiler-mode variable. VIBE_HASH is
# evaluated before VIBE_ALLOCS in cli_adapter, so leaking it changes the verb.
ENV_RUNNER="$TMP_DIR/env-runner"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${VIBE_HASH:-}" = "1" ]; then exit 41; fi' \
  'printf "main array 0\n" > "$3"' > "$ENV_RUNNER"
chmod +x "$ENV_RUNNER"
VIBE_HASH=1 VIBE_RUNNER="$ENV_RUNNER" VIBE_CLI_WASM="$CLI" \
  bash "$ROOT_DIR/runtime/vibe" allocs "$SRC" > "$OUT" 2> "$ERR"
if [ "$(cat "$OUT")" != "main array 0" ]; then
  echo "[vibe-allocs-launcher] FAIL: inherited VIBE_HASH diverted the allocs query" >&2
  cat "$ERR" >&2
  exit 1
fi

echo "[vibe-allocs-launcher] ok"

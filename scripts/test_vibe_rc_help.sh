#!/usr/bin/env bash
# `vibe rc-classify --help` / `vibe rc-plan --help` are reports, not "unknown
# command". Pure launcher: a dummy runner is enough to pass the startup check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe-rc-help.XXXXXX")"
cleanup() {
  local status=$?
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

LAUNCHER="$ROOT_DIR/runtime/vibe"
RUNNER="$TMP_DIR/dummy-runner"
OUT="$TMP_DIR/stdout.txt"
ERR="$TMP_DIR/stderr.txt"

printf '%s\n' '#!/usr/bin/env bash' 'echo "runner-should-not-run" >&2' 'exit 41' > "$RUNNER"
chmod +x "$RUNNER"

run_help() {
  local verb="$1"
  local flag="$2"
  : > "$OUT"
  : > "$ERR"
  local status=0
  VIBE_RUNNER="$RUNNER" bash "$LAUNCHER" "$verb" "$flag" > "$OUT" 2> "$ERR" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "[vibe-rc-help] FAIL: $verb $flag exited $status (want 0)" >&2
    cat "$ERR" >&2
    exit 1
  fi
  if grep -q 'unknown' "$ERR" "$OUT"; then
    echo "[vibe-rc-help] FAIL: $verb $flag still reports unknown" >&2
    cat "$ERR" "$OUT" >&2
    exit 1
  fi
  if [ -s "$ERR" ]; then
    echo "[vibe-rc-help] FAIL: $verb $flag wrote to stderr" >&2
    cat "$ERR" >&2
    exit 1
  fi
  if grep -q 'runner-should-not-run' "$OUT" "$ERR"; then
    echo "[vibe-rc-help] FAIL: $verb $flag invoked the runner" >&2
    exit 1
  fi
}

need() {
  local verb="$1"
  local needle="$2"
  if ! grep -q -- "$needle" "$OUT"; then
    echo "[vibe-rc-help] FAIL: $verb --help missing '$needle'" >&2
    cat "$OUT" >&2
    exit 1
  fi
}

run_help rc-classify --help
need rc-classify 'NAME SET'
run_help rc-classify -h
need rc-classify 'borrow_ret'

run_help rc-plan --help
need rc-plan 'FN BINDING ACTION COUNT'
run_help rc-plan -h
need rc-plan 'alias_dup'

echo "[vibe-rc-help] ok"

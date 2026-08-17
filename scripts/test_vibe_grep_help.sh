#!/usr/bin/env bash
# `vibe grep --help` / `-h` is a report, not "unknown flag" (#1943).
# Pure launcher: a dummy runner is enough to pass the startup check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vibe-grep-help.XXXXXX")"
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
  local flag="$1"
  : > "$OUT"
  : > "$ERR"
  local status=0
  VIBE_RUNNER="$RUNNER" bash "$LAUNCHER" grep "$flag" > "$OUT" 2> "$ERR" || status=$?
  if [ "$status" -ne 0 ]; then
    echo "[vibe-grep-help] FAIL: grep $flag exited $status (want 0)" >&2
    cat "$ERR" >&2
    exit 1
  fi
  if grep -q 'unknown flag' "$ERR" "$OUT"; then
    echo "[vibe-grep-help] FAIL: grep $flag still reports unknown flag" >&2
    cat "$ERR" "$OUT" >&2
    exit 1
  fi
  if [ -s "$ERR" ]; then
    echo "[vibe-grep-help] FAIL: grep $flag wrote to stderr" >&2
    cat "$ERR" >&2
    exit 1
  fi
  if grep -q 'runner-should-not-run' "$OUT" "$ERR"; then
    echo "[vibe-grep-help] FAIL: grep $flag invoked the runner" >&2
    exit 1
  fi
}

need() {
  if ! grep -qF -- "$1" "$OUT"; then
    echo "[vibe-grep-help] FAIL: help missing '$1'" >&2
    cat "$OUT" >&2
    exit 1
  fi
}

run_help --help
need '$(name:kind)'
need 'exp / id / const / arg / args / pat / type'
need '--where'
need '--where-row'
need '--only-ill-typed'
need '--only-well-typed'
need '--json'
need 'Empty output = no match'
need 'bad pattern'

run_help -h
need '$(name:kind)'
need '--where'

echo "[vibe-grep-help] ok"

#!/usr/bin/env bash
# Run each fixture in an isolated subprocess to detect abort/crash.
# Reports: pass, fail (error), crash (abort/signal), timeout, skip.
#
# Usage:
#   scripts/test_fixtures_isolation.sh                # all fixtures
#   scripts/test_fixtures_isolation.sh fixtures/foo.vibe  # specific files
#
# Env:
#   VIBE_FIXTURE_TIMEOUT  per-fixture timeout in seconds (default: 5)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIBE_CLI_RELEASE=1 source "$ROOT_DIR/scripts/ensure_native_cli.sh"
CLI="$VIBE_CLI_BIN"
TIMEOUT="${VIBE_FIXTURE_TIMEOUT:-5}"
TMPDIR="${TMPDIR:-/tmp}"

declare -a files
if [[ $# -gt 0 ]]; then
  files=("$@")
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$ROOT_DIR/fixtures" -maxdepth 1 -name '*.vibe' -type f | sort)
fi

total=${#files[@]}
pass=0
fail=0
crash=0
skip=0
timeout_count=0

crashes=()
fails=()
timeouts=()

tmpf="$TMPDIR/vibe_fixture_isolation_$$.vibe"
trap 'rm -f "$tmpf"' EXIT

for f in "${files[@]}"; do
  # Extract script part (before __DATA__)
  sed -n '/^__DATA__$/q;p' "$f" > "$tmpf"

  if [[ ! -s "$tmpf" ]]; then
    skip=$((skip + 1))
    continue
  fi

  # Run in subprocess with timeout
  set +e
  output="$(timeout "$TIMEOUT" "$CLI" run "$tmpf" 2>&1)"
  rc=$?
  set -e

  basename="$(basename "$f")"

  if [[ $rc -eq 124 ]]; then
    # timeout
    timeout_count=$((timeout_count + 1))
    timeouts+=("$basename")
  elif [[ $rc -eq 134 || $rc -eq 139 || $rc -eq 137 || $rc -gt 128 ]]; then
    # 134=SIGABRT, 139=SIGSEGV, 137=SIGKILL, >128=signal
    crash=$((crash + 1))
    sig=$((rc - 128))
    crashes+=("$basename (signal=$sig, rc=$rc)")
  elif [[ $rc -ne 0 ]]; then
    # non-zero but not signal = eval error (expected for some fixtures)
    fail=$((fail + 1))
    fails+=("$basename")
  else
    pass=$((pass + 1))
  fi
done

echo ""
echo "=== fixture isolation report ==="
echo "total=$total pass=$pass fail=$fail crash=$crash timeout=$timeout_count skip=$skip"

if [[ ${#crashes[@]} -gt 0 ]]; then
  echo ""
  echo "[CRASH] abort/signal detected (these kill the test process):"
  for c in "${crashes[@]}"; do
    echo "  $c"
  done
fi

if [[ ${#timeouts[@]} -gt 0 ]]; then
  echo ""
  echo "[TIMEOUT] exceeded ${TIMEOUT}s (possible infinite loop):"
  for t in "${timeouts[@]}"; do
    echo "  $t"
  done
fi

if [[ ${#crashes[@]} -gt 0 || ${#timeouts[@]} -gt 0 ]]; then
  exit 1
fi

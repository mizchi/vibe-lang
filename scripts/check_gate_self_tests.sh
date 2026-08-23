#!/usr/bin/env bash
# Every gate script must be able to FAIL, and must prove it (#2248 follow-up).
#
# check_selector_precedence.sh reported ok on a hijackable tree five separate
# times. Every one was found by a reviewer rather than by the gate, and every
# red test that proved the fix was run by hand and recorded only in a commit
# message -- so the guarantee did not survive the next edit. The rule that
# would have caught all five is mechanical: a gate ships with a self-test that
# mutates a real input and asserts the gate fails.
#
# This is a RATCHET, like the one in scripts/gate_self_test_allowlist.txt says.
# 18 gates predate the rule and are listed there; entries may be removed by
# writing the test, never added. A NEW gate without a self-test fails here.
set -euo pipefail

# Overridable so this gate's own self-test can point it at a scratch tree.
ROOT_DIR="${VIBE_GATE_SELF_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

ALLOWLIST="scripts/gate_self_test_allowlist.txt"
allowed="$(grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' || true)"

missing=""
for f in scripts/check_*.sh scripts/lint_*.sh; do
  # An unmatched glob arrives as its own literal text; skip it rather than
  # reporting `scripts/lint_*.sh` as a gate with no self-test.
  [ -e "$f" ] || continue
  case "$f" in *_test.sh) continue ;; esac
  base="${f%.sh}"
  [ -f "${base}_test.sh" ] && continue
  name="${f#scripts/}"
  if ! printf '%s\n' "$allowed" | grep -qxF "$name"; then
    missing="$missing $name"
  fi
done

# The allowlist must not rot either: an entry whose test now exists, or whose
# script is gone, is a stale exemption that would silently re-permit a gap.
stale=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if [ ! -f "scripts/$name" ]; then
    stale="$stale $name(script-gone)"
  elif [ -f "scripts/${name%.sh}_test.sh" ]; then
    stale="$stale $name(test-exists)"
  fi
done <<EOF
$allowed
EOF

rc=0
if [ -n "$missing" ]; then
  echo "[gate-self-tests] FAIL: gate scripts with no self-test:" >&2
  for n in $missing; do echo "  scripts/$n" >&2; done
  echo "  Add scripts/<name>_test.sh that mutates a real input and asserts the" >&2
  echo "  gate FAILS -- see scripts/check_selector_precedence_test.sh." >&2
  echo "  A gate that cannot fail is worth nothing." >&2
  rc=1
fi
if [ -n "$stale" ]; then
  echo "[gate-self-tests] FAIL: stale allowlist entries in $ALLOWLIST:" >&2
  for n in $stale; do echo "  $n" >&2; done
  echo "  Remove them -- the ratchet only tightens." >&2
  rc=1
fi
[ "$rc" -eq 0 ] || exit 1

n_all="$(printf '%s\n' "$allowed" | grep -c . || true)"
echo "[gate-self-tests] ok (every gate has a self-test; $n_all pre-existing exemptions)"

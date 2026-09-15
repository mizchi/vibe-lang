#!/usr/bin/env bash
# Self-test for check_selector_precedence.sh.
#
# This file exists because the check it guards was WRONG FIVE TIMES, and every
# time it was wrong in the same way: it reported ok on a tree that was actually
# hijackable. Each of those was caught by a human reviewer, fixed, and verified
# by a red test I ran BY HAND and recorded only in a commit message -- which
# means the guarantee evaporated the moment the next person touched the file.
#
# So each historical defect is a case below. A check that cannot fail is worth
# nothing, and the only way to know it can fail is to make it fail.
#
# Every case MUTATES a copy of the real launcher, so each one also asserts that
# its mutation LANDED. A red test whose edit silently matched nothing passes
# while proving nothing -- that happened here too (the order block is
# multi-line, and a slice grabbed only its first line), so "mutation applied"
# is checked before "check failed" is believed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CHECK="$ROOT_DIR/scripts/check_selector_precedence.sh"
ADAPTER="lib/@vibe/compiler/cli_adapter.vibe"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_selprec_test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "[selector-precedence-test] FAIL: $1" >&2; exit 1; }

# Green first: an unmutated copy must pass, or every red case below is
# meaningless (they would "fail" for reasons unrelated to their mutation).
cp runtime/vibe "$WORK/launcher"
if ! bash "$CHECK" "$ADAPTER" "$WORK/launcher" >/dev/null 2>&1; then
  bash "$CHECK" "$ADAPTER" "$WORK/launcher" >&2 || true
  fail "the unmutated launcher does not pass -- every case below is void"
fi

# red <name> <expected-substring> <python-mutation>
#   The mutation edits $WORK/launcher. It MUST change the file, and the check
#   MUST then fail with a message naming the defect.
red() {
  local name="$1" expect="$2" mutation="$3"
  cp runtime/vibe "$WORK/launcher"
  # The mutation travels in the ENVIRONMENT, not through the heredoc: an
  # unquoted heredoc rewrites `$` before python sees it, which silently turned
  # every pattern into one that matches nothing -- a whole suite of red cases
  # that could not fail.
  if ! VIBE_SELPREC_MUTATION="$mutation" python3 - "$WORK/launcher" <<'PY'
import io, os, sys
path = sys.argv[1]
s = io.open(path, encoding="utf-8").read()
ns = {"s": s}
exec(os.environ["VIBE_SELPREC_MUTATION"], ns)
out = ns["out"]
if out == s:
    sys.exit("mutation matched nothing")
io.open(path, "w", encoding="utf-8").write(out)
PY
  then
    fail "$name: the mutation did not apply -- this case proves nothing"
  fi
  if bash "$CHECK" "$ADAPTER" "$WORK/launcher" >"$WORK/out" 2>&1; then
    fail "$name: the check reported ok on a tree that is hijackable"
  fi
  if ! grep -q "$expect" "$WORK/out"; then
    echo "--- got ---" >&2; cat "$WORK/out" >&2
    fail "$name: failed, but not for the reason under test (wanted: $expect)"
  fi
  echo "  ok  $name"
}

echo "[selector-precedence-test] each historical defect, as a case:"

# Argv dispatch: the launcher must not grow a VIBE_*=1 assignment without
# embedding the adapter order the old env-selector arms used to derive
# predecessor clears from.
red "sets a selector without an order list" \
    "has no VIBE_SELECTOR_ORDER" \
    'out = s.replace("invoke_cli() {", "invoke_cli() {\nVIBE_FMT=1 true\n", 1)'

echo "[selector-precedence-test] ok"

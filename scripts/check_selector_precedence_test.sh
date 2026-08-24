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

# #2239: an arm's hand-written clear list was copied from a neighbour and was
# missing six selectors, so `VIBE_CHECK_ONLY=1 vibe fmt f.vibe` wrote `ok` over
# the user's source.
red "an arm drops its derived clears" \
    "does not clear" \
    'out = s.replace("env $(selector_clears_before VIBE_EMIT_WIT)", "env", 1)'

# #2246: the embedded order is what every arm trusts; drift from the adapter
# silently computes clears against the wrong predecessor set.
red "a selector is dropped from the embedded order" \
    "out of sync" \
    'out = s.replace("VIBE_SELECTOR_ORDER=\"VIBE_LSP ", "VIBE_SELECTOR_ORDER=\"", 1)'

# #2246: same names, different order -- the clear sets are still wrong.
red "the embedded order is permuted" \
    "out of sync" \
    '''i = s.index("VIBE_SELECTOR_ORDER=\"")
j = s.index("\"", s.index("\\n", i))
body = s[i+21:j].split()
body[0], body[1] = body[1], body[0]
out = s[:i+21] + " ".join(body) + s[j:]'''

# #2246: a clear target the derivation does not know falls off the end of
# selector_clears_before's loop and clears EVERYTHING -- by accident, not by
# derivation, and indistinguishable from working.
red "a clear target the derivation does not know" \
    "not a selector this derivation knows" \
    'out = s.replace("selector_clears_before VIBE_BACKEND", "selector_clears_before VIBE_NOPE", 1)'

# #2248 review, rounds 3 and 4: routing the clears through a VARIABLE was
# broken twice more -- `; sel_clears=""` on the same line as the declaration,
# and `false && ` in front of it. Both are now impossible rather than
# detected: a variable carrying the clears is rejected outright, so the
# scanner never has to understand shell assignment at all.
red "the clears are routed through a variable" \
    "unresolved expansion" \
    'out = s.replace("    env $(selector_clears_before VIBE_FS_COMPILE) $fs_env", "    local sc=\"$(selector_clears_before VIBE_FS_COMPILE)\"\n    env $sc $fs_env", 1)'

# ...and the gc lane must carry its own, since the two lanes are two calls.
red "the gc lane drops its inline clears" \
    "unresolved expansion" \
    'out = s.replace("    env $(selector_clears_before VIBE_BACKEND)", "    env", 1)'

# The helper's TEXT is not the helper RUNNING. Single quotes stop the shell
# expanding `$( ... )`, so this passes a literal string to `env` and clears
# nothing -- and the scan credited it, because it matched characters rather
# than an executable command substitution (#2248 review). The scan now deletes
# single-quoted spans before looking.
red "the helper is spelled inside single quotes" \
    "unresolved expansion" \
    "out = s.replace('env \$(selector_clears_before VIBE_BACKEND)', chr(101)+chr(110)+chr(118)+chr(32)+chr(39)+'X=\$(selector_clears_before VIBE_BACKEND)'+chr(39), 1)"

# ...and in DOUBLE quotes, which is the sharper of the two. The helper really
# does run; its whole output then becomes one `X=...` argument, which `env`
# accepts as a valid assignment and which passes no `-u` at all. I left this
# open deliberately in the previous round, arguing the runner would surface it.
# It does not (#2248 review).
red "the helper is spelled inside double quotes" \
    "unresolved expansion" \
    "out = s.replace('env \$(selector_clears_before VIBE_BACKEND)', chr(101)+chr(110)+chr(118)+chr(32)+chr(34)+'X=\$(selector_clears_before VIBE_BACKEND)'+chr(34), 1)"

# Five cases used to live here, all mutating the variable that carried the
# clears (an uncovered path, an underived narrowing, an assignment behind
# `&&`, one after `;`, a deleted declaration). Routing them through a variable
# is now rejected outright, so those constructs cannot occur -- and a case
# whose mutation matches nothing proves nothing. This suite told me so by
# failing when they went stale, which is the property it exists for. They are
# replaced by the two above: no variable, and each lane carries its own call.

echo "[selector-precedence-test] ok"

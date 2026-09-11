#!/usr/bin/env bash
# The pkfire pin is one value, declared once, and honoured (#2645 follow-up).
#
# `uses: mizchi/pkfire@vX` names the ACTION's ref, not the pkf release it
# installs. The action resolves the release from an input, and with none passed
# it falls through to "latest" -- so CI ran `pkfire@0.16.0` under a ref that
# said v0.14.2, on every job, silently (measured on run 34567587111). Three
# places declared a version and none of them matched what ran.
#
# .github/pkfire-version is now the single value. This gate checks, lexically,
# that every declaration agrees with it:
#
#   - each `uses: mizchi/pkfire@vX` ref
#   - each `version:` input passed to that action
#   - .claude/hooks/session-start.sh, which must READ the file rather than
#     hardcode a number (a hardcoded one drifts exactly the way this bug did)
#
# What it cannot check is what the action actually installs -- only CI can see
# that, which is why each workflow also asserts `pkf version` after installing.
#
# The `uses:` scan is ANCHORED to the start of a line so this gate cannot read
# its own prose: the first draft matched the example inside the comment above
# and reported a call site pinned at "vX". That is the #2138 shape -- a checker
# counting its own text as evidence -- and a comment is exactly where it hides.
set -euo pipefail

ROOT_DIR="${VIBE_PKFIRE_PIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT_DIR"

PIN_FILE=".github/pkfire-version"
if [ ! -s "$PIN_FILE" ]; then
  echo "[pkfire-pin] FAIL: no $PIN_FILE -- it is the single source of the pin" >&2
  exit 1
fi
want="$(tr -d '[:space:]' < "$PIN_FILE")"
case "$want" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "[pkfire-pin] FAIL: $PIN_FILE is not a version: '$want'" >&2; exit 1 ;;
esac

rc=0
refs=0
withs=0

# Every `uses: mizchi/pkfire@<ref>` must name the pinned version.
while IFS=: read -r file line rest; do
  [ -n "${file:-}" ] || continue
  refs=$((refs + 1))
  ref="$(printf '%s' "$rest" | sed 's/.*mizchi\/pkfire@//; s/[[:space:]].*//')"
  if [ "$ref" != "v$want" ]; then
    echo "[pkfire-pin] FAIL: $file:$line pins the action at '$ref', $PIN_FILE says v$want" >&2
    rc=1
  fi
done <<EOF
$(grep -rnE '^[[:space:]]*(- )?uses:[[:space:]]*mizchi/pkfire@' .github 2>/dev/null || true)
EOF

# ...and each of those call sites must pass the release as an input, because
# the ref alone does not select it.
# `|| true` inside the pipeline: under `set -o pipefail` a grep that finds
# nothing (or whose file is absent) makes the substitution fail and `set -e`
# kills the script with no message at all -- which is how the "no call sites"
# case first behaved. A gate that dies silently is worse than one that passes
# wrongly, because nobody even sees a verdict.
withs="$( { grep -rc "version:[[:space:]]*$want" .github/actions/setup-vibe/action.yml .github/workflows/pkfire-pkspec.yml 2>/dev/null || true; } | awk -F: '{s+=$2} END {print s+0}')"

if [ "$refs" -eq 0 ]; then
  echo "[pkfire-pin] FAIL: found no 'uses: mizchi/pkfire@' at all -- the scan did not run" >&2
  exit 1
fi
if [ "$withs" -lt "$refs" ]; then
  echo "[pkfire-pin] FAIL: $refs call site(s) but only $withs pass 'version: $want'" >&2
  echo "  Without the input the action installs 'latest' and the ref decides nothing." >&2
  rc=1
fi

# The hook must READ the pin, not restate it.
HOOK=".claude/hooks/session-start.sh"
if [ -f "$HOOK" ]; then
  if ! grep -q "pkfire-version" "$HOOK"; then
    echo "[pkfire-pin] FAIL: $HOOK does not read $PIN_FILE" >&2
    echo "  A second hardcoded version is how CI and local dev drifted apart." >&2
    rc=1
  fi
  if grep -qE '^PKF_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$HOOK"; then
    echo "[pkfire-pin] FAIL: $HOOK hardcodes PKF_VERSION instead of reading $PIN_FILE" >&2
    rc=1
  fi
fi

[ "$rc" -eq 0 ] || exit 1
echo "[pkfire-pin] ok ($want; $refs call site(s), $withs pinned input(s))"

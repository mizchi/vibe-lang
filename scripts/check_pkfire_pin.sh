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

# PER CALL SITE, not an aggregate count (Codex review of #2645). Comparing
# "how many refs" against "how many version: lines anywhere" does not establish
# that each step has its own input: deleting the input from one file and
# leaving the YAML comment `# version: 0.14.2` behind kept the totals equal and
# the gate green, while that action went back to installing latest.
#
# So each `uses:` is associated with ITS OWN step. The window runs from the
# uses line to the next list item at the same or shallower indent, and a
# `version:` only counts when it is a real key -- a commented line cannot match
# an anchored `^[[:space:]]*version:`.
scan="$( { grep -rlE '^[[:space:]]*(- )?uses:[[:space:]]*mizchi/pkfire@' .github 2>/dev/null || true; } | while IFS= read -r f; do
  [ -n "$f" ] || continue
  awk -v want="$want" -v file="$f" '
    function indent(s,   i) { match(s, /^[[:space:]]*/); return RLENGTH }
    /^[[:space:]]*(- )?uses:[[:space:]]*mizchi\/pkfire@/ {
      if (in_site) { printf "%s:%d:%s:%s\n", file, site_line, site_ref, (found ? "ok" : "missing") }
      in_site = 1; found = 0; site_line = NR; site_indent = indent($0)
      site_ref = $0; sub(/.*mizchi\/pkfire@/, "", site_ref); sub(/[[:space:]].*/, "", site_ref)
      next
    }
    in_site && /^[[:space:]]*-[[:space:]]/ && indent($0) <= site_indent {
      printf "%s:%d:%s:%s\n", file, site_line, site_ref, (found ? "ok" : "missing")
      in_site = 0; next
    }
    in_site && $0 ~ ("^[[:space:]]*version:[[:space:]]*" want "[[:space:]]*$") { found = 1 }
    END { if (in_site) printf "%s:%d:%s:%s\n", file, site_line, site_ref, (found ? "ok" : "missing") }
  ' "$f"
done )"

while IFS=: read -r file line ref verdict; do
  [ -n "${file:-}" ] || continue
  refs=$((refs + 1))
  if [ "$ref" != "v$want" ]; then
    echo "[pkfire-pin] FAIL: $file:$line pins the action at '$ref', $PIN_FILE says v$want" >&2
    rc=1
  fi
  if [ "$verdict" = "ok" ]; then
    withs=$((withs + 1))
  else
    echo "[pkfire-pin] FAIL: $file:$line passes no 'version: $want' input" >&2
    rc=1
  fi
done <<EOF
$scan
EOF

if [ "$refs" -eq 0 ]; then
  echo "[pkfire-pin] FAIL: found no 'uses: mizchi/pkfire@' at all -- the scan did not run" >&2
  exit 1
fi
if [ "$withs" -lt "$refs" ]; then
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

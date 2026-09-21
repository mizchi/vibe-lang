#!/usr/bin/env bash
# Red/green for check_release_draft_promote.sh (#2248: a gate means nothing
# until it is shown to fail).
#
# Each case mutates a COPY of the real workflow and asserts the gate rejects
# it. The unmutated copy must pass, or the mutations prove nothing.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/scripts/check_release_draft_promote.sh"
SRC="$ROOT_DIR/.github/workflows/release.yml"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-release-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

run_gate() { RELEASE_WORKFLOW="$1" bash "$GATE" >/dev/null 2>&1; }

# 0. CONTROL -- the real workflow passes. Without this the reds below could be
#    failing for an unrelated reason.
cp "$SRC" "$WORK/green.yml"
if run_gate "$WORK/green.yml"; then note "  ok   control: the real workflow passes"
else note "  FAIL control: the real workflow does not pass the gate"; fail=1; fi

# Each mutation must actually change the file, or the case is vacuous -- a
# no-op edit passes while proving nothing (the exact trap #2248 records).
mutate() { # mutate <name> <sed-expr>
  local name="$1" expr="$2" out="$WORK/$1.yml"
  sed "$expr" "$SRC" > "$out"
  if cmp -s "$SRC" "$out"; then
    note "  FAIL $name: the mutation matched nothing -- this case proves nothing"
    fail=1; return 1
  fi
  return 0
}

assert_red() { # assert_red <name> <description>
  if run_gate "$WORK/$1.yml"; then
    note "  FAIL $1: gate PASSED a workflow that $2"
    fail=1
  else
    note "  ok   red: rejected a workflow that $2"
  fi
}

mutate no_draft     '/^ *draft: true$/d'                       && assert_red no_draft     "publishes directly instead of staging a draft"
mutate no_promote   's/gh release edit "\${GITHUB_REF_NAME}" --draft=false/echo skip/'  && assert_red no_promote   "never promotes the draft"
mutate no_verify    's/assets=\$want_assets/assets=whatever/'  && assert_red no_verify    "does not check the published asset count"
mutate no_pre_check 's/prerelease=\$want_pre/prerelease=maybe/' && assert_red no_pre_check "does not check the published prerelease flag"

note
if [ "$fail" = 0 ]; then note "[release-draft-promote-test] ok"; else note "[release-draft-promote-test] FAIL"; fi
exit "$fail"

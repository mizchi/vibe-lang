#!/usr/bin/env bash
# Red/green for check_release_draft_promote.vibex (#2248: a gate means nothing
# until it is shown to fail; #3672 ported the gate).
#
# Each case mutates a COPY of the real workflow and asserts the gate rejects
# it. The unmutated copy must pass, or the mutations prove nothing.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SRC="$ROOT_DIR/.github/workflows/release.yml"
# The gate reads only inside the repository, so the copies live under _build/.
WORK_REL="_build/release_draft_promote_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }

run_gate() { # run_gate <copy under $WORK>
  bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_release_draft_promote.vibex -- --workflow "$WORK_REL/${1#"$WORK"/}" >/dev/null 2>&1
}

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

# The promotion split across two lines is not a promotion: the command and
# its flag must be on one line.
mutate split_promote 's/gh release edit "\${GITHUB_REF_NAME}" --draft=false/gh release edit "${GITHUB_REF_NAME}" \\\n  --draft=false/' && assert_red split_promote "splits the promote command from its --draft=false flag"
# `draft: true` with no indentation is not a step input.
mutate unindented_draft 's/^ *draft: true$/draft: true/' && assert_red unindented_draft "moves draft: true out of the step"
# A workflow that is not there is refused, not passed.
if run_gate "$WORK/absent.yml"; then note "  FAIL absent: gate PASSED a workflow that does not exist"; fail=1
else note "  ok   red: rejected a workflow that does not exist"; fi

note
if [ "$fail" = 0 ]; then note "[release-draft-promote-test] ok"; else note "[release-draft-promote-test] FAIL"; fi
exit "$fail"

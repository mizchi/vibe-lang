#!/usr/bin/env bash
# Red test for check_capability_preflight.sh (#2248: a gate means nothing
# until it is shown to be able to FAIL).
#
# The mutation is the compiler, not the script. This gate's whole subject is
# "does a RUN reach the preflight", and the honest counter-example is a
# compiler in which it does not -- which is every stage2 built before #2828's
# rung 1. So the red case hands the gate a PRE-FIX artifact and asserts it
# fails; a gate that passed there would be reporting on a ladder that is not
# connected, which is exactly the state this gate exists to detect.
#
# Environment: every variable the gate reads is unset first (#2252 -- five
# self-tests were once silently no-ops because the session hook exported a
# variable they inherited), then set explicitly per case.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# The lane hands this test the compiler it should treat as "current"; keep it
# before the unset below, which exists so each case sets what it needs rather
# than inheriting it (#2252).
LANE_STAGE2="${CAPABILITY_PREFLIGHT_STAGE2:-}"
unset CAPABILITY_PREFLIGHT_STAGE2 VIBE_CLI_WASM VIBE_STAGE2_WASM || true

# Does this wasm carry the refusal string this rung added?
#
# NOT `strings "$w" | grep -q`: `grep -q` exits at the first match, `strings`
# then takes SIGPIPE, and under `set -o pipefail` the pipeline reports FAILURE
# on a file that MATCHED. That inverts the answer for every carrying artifact
# -- measured here: the green control reported "no post-#2828 stage2 on disk"
# while the file was sitting there, and the red case was picking the first
# artifact in the glob rather than a verified pre-fix one, so it passed while
# proving nothing (#2248's shape exactly). `grep -c` consumes all of its input,
# so no producer is ever signalled.
carries_fix() {
  [ "$(strings "$1" 2>/dev/null | grep -c 'not a capability; the providers')" -gt 0 ]
}

pass=0; fail=0
ok()  { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# A pre-fix stage2 is any generation whose wasm does NOT carry the refusal
# string this rung added. Picked by content rather than by name, because a
# generation directory is named after a commit and says nothing about what is
# inside it.
pre_fix=""
for w in "$ROOT_DIR"/_build/selfhost/generations/*/stage2.wasm; do
  [ -f "$w" ] || continue
  if ! carries_fix "$w"; then
    pre_fix="$w"
    break
  fi
done

if [ -z "$pre_fix" ]; then
  # Not a pass. The red case could not be constructed, and saying nothing
  # would be indistinguishable from running it.
  echo "n/a: no pre-#2828 stage2 on disk to use as the red input" >&2
  echo "  (build one before this rung, or keep an older generation)" >&2
else
  # First prove the mutation LANDED: the artifact really lacks the string.
  if carries_fix "$pre_fix"; then
    bad "the chosen red input already carries the fix -- the case would prove nothing"
  else
    out="$(CAPABILITY_PREFLIGHT_STAGE2="$pre_fix" bash "$ROOT_DIR/scripts/check_capability_preflight.sh" 2>&1 || true)"
    if printf '%s\n' "$out" | grep -q 'capability-preflight: FAIL'; then
      ok "a compiler without the connected ladder FAILS the gate"
    else
      bad "the gate passed on a pre-fix compiler; it is not testing what it claims: $out"
    fi
  fi
fi

# Green control on the current artifact, so a gate that fails for an unrelated
# reason (a missing runner, a broken launcher) cannot masquerade as the red
# case above.
# The green control is a MEASUREMENT of the compiler under test, so it has no
# honest fallback (AGENTS.md, "A MEASUREMENT has no honest fallback"). It uses
# the artifact the lane handed us and nothing else.
#
# It used to scan the generations glob when the lane gave it nothing, and that
# was wrong in a way only rung 2 exposed: `carries_fix` detects RUNG 1's
# refusal string, so a rung-1-only stage2 looks "post-fix" to it. The glob duly
# picked one, the four rung-2 cases ran against a compiler that predates them,
# and the self-test reported a failure that said nothing about the tree. There
# is no string that distinguishes rung 2 -- it adds behaviour, not text -- so
# guessing the artifact cannot be made safe. Refuse instead.
post_fix=""
if [ -n "$LANE_STAGE2" ] && [ -f "$LANE_STAGE2" ]; then
  if carries_fix "$LANE_STAGE2"; then
    post_fix="$LANE_STAGE2"
  else
    bad "the lane's compiler does not even carry rung 1; it cannot be the green control"
  fi
fi

if [ -z "$post_fix" ]; then
  echo "n/a: the green control needs CAPABILITY_PREFLIGHT_STAGE2 pointing at" >&2
  echo "  the compiler built from this tree; it will not guess one from disk." >&2
else
  out="$(CAPABILITY_PREFLIGHT_STAGE2="$post_fix" bash "$ROOT_DIR/scripts/check_capability_preflight.sh" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -q '10 passed, 0 failed'; then
    ok "a compiler with the connected ladder PASSES the gate"
  else
    bad "the green control did not pass: $out"
  fi
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]

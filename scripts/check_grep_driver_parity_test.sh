#!/usr/bin/env bash
# check_grep_driver_parity_test.sh -- prove check_grep_driver_parity.sh can
# FAIL.
#
# #2248: a gate that has never been seen to fail certifies nothing.
#
# Every mutation hits `runtime/vibe`, because that is the half the parity gate
# exists for. `scripts/vibe_grep_bin.sh` already has two gates of its own; what
# nothing checked until now is whether the SECOND driver, written against a
# different CLI entry point in a file that can source nothing, still answers
# the same.
#
# The four cases are the four ways that duplication plausibly rots, one per
# property:
#
#   * a chunk loses its last line          -> the drivers disagree (1, 2)
#   * JSON is emitted per chunk            -> the arrays disagree (3)
#   * the resume index is ignored          -> files are skipped at a budget (4)
#   * the support probe never succeeds     -> the loop silently does not run,
#                                             which is the failure the whole
#                                             gate is built around (4)
#
# The last one is the important one. Without property 4 every other assertion
# in the gate is satisfied by a `runtime/vibe` that never loops at all, since a
# fallback to the single call agrees with the env-mode driver perfectly.
#
# Each mutation is asserted to have CHANGED the file, and the mutant is
# asserted to still PARSE, before the gate runs. An edit that matches nothing
# leaves a pristine driver and the gate's pass would be recorded as proof; an
# edit that breaks the shell reddens the gate for a reason that has nothing to
# do with the property. Both have happened in this repo.
#
#   GREP_PARITY_STAGE2=<stage2.wasm> bash scripts/check_grep_driver_parity_test.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_grep_driver_parity.sh"
DRIVER="runtime/vibe"
[ -f "$GATE" ] || { echo "grep-driver-parity-test: missing $GATE" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "grep-driver-parity-test: missing $DRIVER" >&2; exit 1; }

# #2252: inherit nothing. A variable the session hook exported would steer
# these runs, and a case that no-ops looks exactly like a case that passed.
unset VIBE_GREP_CHUNK_FILES
unset VIBE_GREP_MEMORY_BUDGET_MB
unset VIBE_GREP_MEMORY_SAFETY_FACTOR
unset VIBE_CLI_WASM
unset VIBE_REVIEW_LINT_GREP_BIN

# Resolve ONCE and hand it down. The gate refuses without a compiler that has
# the chunk mode, and a refusal would redden every mutation for a reason that
# has nothing to do with the mutation -- the failure this file exists to rule
# out.
. "$ROOT_DIR/scripts/resolve_stage2.sh"
STAGE2="$(resolve_stage2_strict grep-driver-parity-test "${GREP_PARITY_STAGE2:-${VIBE_STAGE2_WASM:-}}")" || exit 1
export GREP_PARITY_STAGE2="$STAGE2"

# MUTATE A COPY, never `runtime/vibe` itself. That file is the repo's own
# launcher -- the SessionStart hook and other tooling reach for it -- so an
# in-place mutation is live for everything else in the checkout for as long as
# a case runs, and an interrupted run leaves it mutated or worse. Measured: one
# interrupted run left `runtime/vibe` a ZERO-BYTE file, recovered only because
# this script's own backup happened to still be in /tmp.
#
# The copy lives in runtime/ so `$SELF` (and the help text's self-`sed`)
# resolve exactly as they do for the real launcher; the gate is pointed at it
# with GREP_PARITY_LAUNCHER.
MUTANT="$ROOT_DIR/runtime/.grep_parity_mutant"
PRISTINE="$(mktemp)"
cp "$DRIVER" "$PRISTINE"
cleanup() { rm -f "$MUTANT" "$MUTANT.bak" "$PRISTINE"; }
trap cleanup EXIT
export GREP_PARITY_LAUNCHER="$MUTANT"

passed=0
fail() { echo "grep-driver-parity-test: FAIL: $*" >&2; exit 1; }

expect_red() { # <name> <sed-expr>
  local name="$1" expr="$2" status=0
  cp "$PRISTINE" "$MUTANT"
  sed -i.bak "$expr" "$MUTANT"
  rm -f "$MUTANT.bak"
  chmod +x "$MUTANT"
  if cmp -s "$PRISTINE" "$MUTANT"; then
    fail "$name: the mutation changed NOTHING, so this case proves nothing"
  fi
  if ! bash -n "$MUTANT" 2>/dev/null; then
    fail "$name: the mutated launcher does not PARSE, so the gate would redden
on a shell syntax error rather than on the property under test"
  fi
  bash "$GATE" >/dev/null 2>&1 || status=$?
  rm -f "$MUTANT"
  if [ "$status" = "0" ]; then
    fail "$name: the mutated launcher PASSED the gate; that property is not
actually being checked"
  fi
  echo "grep-driver-parity-test: ok -- $name reddens the gate (exit $status)"
  passed=$((passed + 1))
}

# Unmutated first, or every case below is red for an unrelated reason.
status=0
GREP_PARITY_LAUNCHER="$DRIVER" bash "$GATE" >/dev/null 2>&1 || status=$?
[ "$status" = "0" ] || fail "the UNMUTATED gate does not pass (exit $status).
Run it directly to see why; until it passes, no mutation below proves anything."
echo "grep-driver-parity-test: ok -- the unmutated gate passes"

# Every chunk loses its last line. A boundary-shaped loss, not a whole chunk,
# so a check that compared only totals at one chunk size could miss it.
expect_red "each chunk loses its last line" \
  's|^        cat "\$chunkout"$|        sed "$d" "$chunkout"|'

# JSON emitted per chunk instead of reassembled: several arrays in one answer.
# `#` as the delimiter because the target line contains a `|` pipe.
expect_red "JSON per chunk instead of one array" \
  '/>> "\$jsonbody"$/s#.*#        cat "$chunkout" >> "$jsonbody"#'

# The resume index is ignored and the loop advances by the whole slice. Files
# the sweep never reached are skipped in silence -- it stopped early and the
# driver reported success for the part it never asked about. Only visible at a
# budget small enough to force a hand-off, which is what property 4 sets up.
expect_red "the resume index is ignored" \
  's|^      advance="\$(tr -d .\[:space:\]. < "\$resumef")"$|      advance="$slice"|'

# The support probe never succeeds, so the driver always falls back to the
# single call. THIS is the case the gate is built around: the fallback agrees
# with the env-mode driver on every ordinary query, so properties 1-3 all still
# hold and only property 4 -- answering at a budget no single process can
# finish under -- can tell the difference.
expect_red "the support probe never succeeds" \
  's|!= "vibe-grep-file-list-v1" \]; then|!= "vibe-grep-file-list-vNEVER" ]; then|'

echo "grep-driver-parity-test: ok ($passed mutations reddened the gate)"

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

WORK_LOG="$(mktemp "${TMPDIR:-/tmp}/vibe_gate_selftest.XXXXXX")"
trap 'rm -f "$WORK_LOG"' EXIT

ALLOWLIST="scripts/gate_self_test_allowlist.txt"
FAILING="scripts/gate_self_test_failing.txt"
allowed="$(grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$' || true)"
failing_allowed="$(grep -v '^\s*#' "$FAILING" | grep -v '^\s*$' || true)"

# BASELINE PIN. Documenting "deletion only" does not enforce it: a new gate
# with no self-test could simply be appended to the allowlist and accepted
# (#2248 review). The sets below are the exemptions that existed when each
# rule landed. Anything not in them is rejected even if it is listed, so the
# ratchet can only tighten.
# Overridable ONLY so this gate's own self-test can pin a scratch baseline --
# the same escape hatch as VIBE_GATE_SELF_TEST_ROOT above, and unset on every
# real invocation.
baseline_no_test="${VIBE_GATE_SELF_TEST_BASELINE:-}"
baseline_failing="${VIBE_GATE_SELF_TEST_BASELINE_FAILING:-}"
if [ -z "$baseline_no_test$baseline_failing" ]; then
baseline_no_test="check_book_order.sh check_book_skip_blocks.sh
check_builtin_parity.sh check_cheatsheet_signatures.sh
check_cli_line_termination.sh check_declaration_scale.sh check_doc_commands.sh
check_examples_typecheck.sh check_fixture_execution.sh
check_inline_builtin_capture.sh check_offbuild_typecheck.sh
check_package_sibling_scope.sh check_playground_presets.sh
check_portable_boundary.sh check_rc_default.sh
check_tutorial_translation_parity.sh check_typecheck_fixtures.sh
check_vibe_fmt.sh"
baseline_failing="lint_review_regressions_test.sh
lint_tracked_experiment_names_test.sh"
fi

not_baseline=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' $baseline_no_test | grep -qxF "$name" || not_baseline="$not_baseline $ALLOWLIST:$name"
done <<EOF2
$allowed
EOF2
while IFS= read -r name; do
  [ -n "$name" ] || continue
  printf '%s\n' $baseline_failing | grep -qxF "$name" || not_baseline="$not_baseline $FAILING:$name"
done <<EOF3
$failing_allowed
EOF3
if [ -n "$not_baseline" ]; then
  echo "[gate-self-tests] FAIL: exemptions that are not in the pinned baseline:" >&2
  for n in $not_baseline; do echo "  $n" >&2; done
  echo "  These lists only SHRINK. A new gate needs a self-test, not an entry." >&2
  exit 1
fi

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

# RUN every companion, do not merely count them. Accepting a self-test because
# its FILE EXISTS makes the whole guarantee a filename convention: a companion
# that fails stays unexecuted while this gate reports success, which is the
# exact shape ("the check credited a proxy for the property") that this gate
# was written to stop (#2248 review). Discovery is by glob, so a future
# companion is run without anyone remembering to add it to a list.
failed_tests=""
if [ "${VIBE_GATE_SELF_TESTS_RUN:-1}" = "1" ]; then
  for t in scripts/check_*_test.sh scripts/lint_*_test.sh; do
    [ -e "$t" ] || continue
    # Only companions OF a gate in this tree; an orphan is reported below.
    [ -f "${t%_test.sh}.sh" ] || continue
    base="${t#scripts/}"
    if printf '%s\n' "$failing_allowed" | grep -qxF "$base"; then
      continue  # pre-existing failure, tracked in #2252
    fi
    if ! bash "$t" >"$WORK_LOG" 2>&1; then
      failed_tests="$failed_tests $t"
      echo "[gate-self-tests] --- $t ---" >&2
      tail -20 "$WORK_LOG" >&2
    fi
  done
fi

rc=0
if [ -n "$failed_tests" ]; then
  echo "[gate-self-tests] FAIL: gate self-tests that do not pass:" >&2
  for t in $failed_tests; do echo "  $t" >&2; done
  echo "  A self-test that is not run is a filename, not a guarantee." >&2
  rc=1
fi
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

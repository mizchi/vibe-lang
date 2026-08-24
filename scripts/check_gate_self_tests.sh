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
failing_allowed="$(grep -v '^\s*#' "$FAILING" | grep -v '^\s*$' | awk '{print $1}' || true)"
# Only `broken` entries are repair-checked. An `env-dependent` one passing
# here says nothing about CI, and removing it on that evidence turns CI red --
# measured: the three ripgrep-dependent tests pass in the dev container and
# fail in the late lane (#2248 review).
failing_broken="$(grep -v '^\s*#' "$FAILING" | awk '$2 == "broken" {print $1}' || true)"

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

# CORPUS WIDENING, not new exemptions (#2248 review). Discovery covered only
# `check_*` / `lint_*` until now, so these 27 `*_gate.sh` scripts were never
# asked for a self-test. They are pinned exactly as they stood the day the
# scope widened; the list still only SHRINKS from here, and a NEW `*_gate.sh`
# is rejected like any other gate that arrives without a companion.
baseline_no_test="$baseline_no_test
compiler_gate.sh minify_gate.sh test_async_component_gate.sh
test_async_sleep_component_gate.sh test_async_string_lift_probe_gate.sh
test_concurrent_awaits_component_gate.sh test_future_value_component_gate.sh
test_host_future_value_component_gate.sh
test_host_stream_value_probe_gate.sh
test_hostfuture_source_component_gate.sh test_http_body_read_probe_gate.sh
test_http_body_stream_probe_gate.sh test_interleaved_tasks_probe_gate.sh
test_named_hostfutures_component_gate.sh
test_named_hoststreams_component_gate.sh test_parallel_warm_pool_gate.sh
test_serve_async_lift_gate.sh test_serve_body_stream_gate.sh
test_spawned_future_component_gate.sh test_stream_value_component_gate.sh
test_wasi_cli_stdin_p3_probe_gate.sh
test_wasi_cli_stdin_provider_component_gate.sh
test_wasi_cli_stdin_provider_guest_component_gate.sh
test_wasi_cli_stdin_provider_source_component_gate.sh
test_wasi_http_p3_full_gate.sh test_wasi_p3_guarantee_gate.sh
test_wit_async_import_component_gate.sh"
# Pinned EMPTY (#2252): all five original entries were repaired, so any name
# appearing in the failing list from here on is rejected outright. There is no
# longer a supported way to exempt a failing self-test.
baseline_failing=""
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
# `*_gate.sh` too. The rule says EVERY gate ships a self-test, and the check
# covered two prefixes -- so a `verify_release_gate.sh` with no companion was
# silently accepted, which is the documented requirement bypassed outright
# (#2248 review). The existing `*_gate.sh` scripts enter the allowlist as a
# CORPUS WIDENING, not as exemptions anyone granted; see the second baseline
# block below.
for f in scripts/check_*.sh scripts/lint_*.sh scripts/*_gate.sh; do
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
repaired=""
if [ "${VIBE_GATE_SELF_TESTS_RUN:-1}" = "1" ]; then
  for t in scripts/check_*_test.sh scripts/lint_*_test.sh scripts/*_gate_test.sh; do
    [ -e "$t" ] || continue
    # Only companions OF a gate in this tree; an orphan is reported below.
    [ -f "${t%_test.sh}.sh" ] || continue
    base="${t#scripts/}"
    if printf '%s\n' "$failing_allowed" | grep -qxF "$base"; then
      # A known-failing exemption is still RUN, because the interesting case is
      # that it starts passing: skipping it outright means a repaired test (or
      # one whose missing dependency arrived) stays permanently unexecuted, and
      # any later regression in it is invisible until someone edits the list by
      # hand (#2248 review). The ratchet has to notice its own entries going
      # stale, exactly as the no-test allowlist does.
      if bash "$t" >"$WORK_LOG" 2>&1 \
         && printf '%s\n' "$failing_broken" | grep -qxF "$base"; then
        repaired="$repaired $base"
      fi
      continue
    fi
    if ! bash "$t" >"$WORK_LOG" 2>&1; then
      failed_tests="$failed_tests $t"
      echo "[gate-self-tests] --- $t ---" >&2
      tail -20 "$WORK_LOG" >&2
    fi
  done
fi

rc=0
if [ -n "$repaired" ]; then
  echo "[gate-self-tests] FAIL: known-failing exemptions that now PASS:" >&2
  for n in $repaired; do echo "  $n" >&2; done
  echo "  Remove them from $FAILING -- the ratchet only tightens, and an" >&2
  echo "  exemption left in place stops the test from being run at all." >&2
  rc=1
fi
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

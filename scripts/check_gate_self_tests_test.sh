#!/usr/bin/env bash
# Self-test for check_gate_self_tests.sh -- which would otherwise be a gate
# demanding of others what it does not provide itself.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check_gate_self_tests.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe_gate_selftests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/scripts"
fail() { echo "[gate-self-tests-test] FAIL: $1" >&2; exit 1; }
# Bookkeeping cases run with execution OFF (the scratch stubs would only prove
# `#!/usr/bin/env bash` exits 0); the execution behaviour itself is covered by
# run_exec() below. Disabling it for every case left the gate's CENTRAL claim
# untested -- deleting the execution loop entirely still passed this suite
# (#2248 review).
run() {
  VIBE_GATE_SELF_TEST_ROOT="$WORK" \
  VIBE_GATE_SELF_TEST_BASELINE="${SCRATCH_BASELINE:-check_thing.sh}" \
  VIBE_GATE_SELF_TEST_BASELINE_FAILING="none_test.sh" \
  VIBE_GATE_SELF_TESTS_RUN=0 \
  bash "$CHECK" >"$WORK/out" 2>&1
}

hdr() { printf '# scratch\n' > "$WORK/scripts/gate_self_test_allowlist.txt"; }

# A gate WITH a self-test passes.
hdr
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing.sh"
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing_test.sh"
run || { cat "$WORK/out" >&2; fail "a gate with a self-test was rejected"; }
echo "  ok  a gate with a self-test passes"

# Discovery is not limited to two prefixes. It covered only `check_*` and
# `lint_*`, so a gate named any other way -- `verify_release_gate.sh`,
# `minify_gate.sh` -- bypassed the rule entirely and this gate printed ok
# (#2248 review).
hdr
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/verify_release_gate.sh"
if run; then cat "$WORK/out" >&2; fail "a *_gate.sh with no self-test was accepted"; fi
grep -q "verify_release_gate.sh" "$WORK/out" || fail "the failure did not name the *_gate.sh"
echo "  ok  a *_gate.sh with no self-test is rejected"
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/verify_release_gate_test.sh"
hdr
run || { cat "$WORK/out" >&2; fail "a *_gate.sh WITH a self-test was rejected"; }
echo "  ok  a *_gate.sh with a self-test passes"
rm -f "$WORK/scripts/verify_release_gate.sh" "$WORK/scripts/verify_release_gate_test.sh"

# A gate WITHOUT one fails.
rm "$WORK/scripts/check_thing_test.sh"
if run; then fail "a gate with no self-test was accepted"; fi
grep -q "check_thing.sh" "$WORK/out" || fail "the failure did not name the gate"
echo "  ok  a gate with no self-test is rejected"

# ...unless it is a listed pre-existing exemption.
hdr; printf 'check_thing.sh\n' >> "$WORK/scripts/gate_self_test_allowlist.txt"
run || { cat "$WORK/out" >&2; fail "a listed exemption was rejected"; }
echo "  ok  a listed pre-existing exemption passes"

# The ratchet only tightens: once the test exists, the exemption is stale.
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing_test.sh"
if run; then fail "a stale exemption (test now exists) was accepted"; fi
grep -q "test-exists" "$WORK/out" || fail "the failure did not name the stale entry"
echo "  ok  an exemption whose test now exists is rejected"

# An exemption for a script that no longer exists is stale too.
rm "$WORK/scripts/check_thing.sh" "$WORK/scripts/check_thing_test.sh"
if run; then fail "a stale exemption (script gone) was accepted"; fi
grep -q "script-gone" "$WORK/out" || fail "the failure did not name the removed script"
echo "  ok  an exemption for a removed script is rejected"

# An exemption outside the pinned baseline is rejected, so the documented
# deletion-only ratchet is mechanically enforced rather than merely stated.
hdr; printf 'check_thing.sh\n' >> "$WORK/scripts/gate_self_test_allowlist.txt"
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing.sh"
rm -f "$WORK/scripts/check_thing_test.sh"
SCRATCH_BASELINE="something_else.sh" run && fail "an exemption outside the baseline was accepted"
grep -q "not in the pinned baseline" "$WORK/out" || fail "the failure did not name the baseline rule"
echo "  ok  an exemption outside the pinned baseline is rejected"

# THE CENTRAL BEHAVIOUR: a companion that fails must be rejected. Without this
# case, a regression that stops running companions leaves the gate green while
# the guarantee it advertises is gone -- which is the very defect this gate was
# written to stop, so the gate not being tested for it was the same mistake one
# level up.
run_exec() {
  VIBE_GATE_SELF_TEST_ROOT="$WORK" \
  VIBE_GATE_SELF_TEST_BASELINE="check_thing.sh" \
  VIBE_GATE_SELF_TEST_BASELINE_FAILING="none_test.sh" \
  VIBE_GATE_SELF_TESTS_RUN=1 \
  bash "$CHECK" >"$WORK/out" 2>&1
}

hdr
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing.sh"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 1\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then fail "a FAILING companion was accepted"; fi
grep -q "check_thing_test.sh" "$WORK/out" || fail "the failure did not name the companion"
grep -q "do not pass" "$WORK/out" || fail "the failure did not say the companion failed"
echo "  ok  a failing companion is rejected (execution actually happens)"

# ...and a passing one is accepted, so the case above is not passing because
# the gate rejects everything.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
run_exec || { cat "$WORK/out" >&2; fail "a PASSING companion was rejected"; }
echo "  ok  a passing companion is accepted"

echo "[gate-self-tests-test] ok"

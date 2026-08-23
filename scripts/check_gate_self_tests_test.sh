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
run() { VIBE_GATE_SELF_TEST_ROOT="$WORK" bash "$CHECK" >"$WORK/out" 2>&1; }

hdr() { printf '# scratch\n' > "$WORK/scripts/gate_self_test_allowlist.txt"; }

# A gate WITH a self-test passes.
hdr
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing.sh"
printf '#!/usr/bin/env bash\n' > "$WORK/scripts/check_thing_test.sh"
run || { cat "$WORK/out" >&2; fail "a gate with a self-test was rejected"; }
echo "  ok  a gate with a self-test passes"

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

echo "[gate-self-tests-test] ok"

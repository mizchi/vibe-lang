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
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"

# Running companions needs a git work tree (#2899, below), and says so when it
# has none rather than skipping the tree check -- "unchecked" must not read
# as "clean".
if run_exec; then cat "$WORK/out" >&2; fail "companions ran outside a git work tree without the tree check"; fi
grep -q "not a git work tree" "$WORK/out" || { cat "$WORK/out" >&2; fail "the no-work-tree refusal did not say why"; }
echo "  ok  running companions outside a git work tree is refused, not silently unchecked"

# The scratch tree becomes a repository with a tracked "compiler source", the
# shape #2899 found probe code left in. The gate's own output file is excluded
# so the harness is not what dirties the tree.
mkdir -p "$WORK/lib"
printf 'fn real() -> Int {\n  1\n}\n' > "$WORK/lib/source.vibe"
git -C "$WORK" init -q
printf 'out\n' >> "$WORK/.git/info/exclude"
git -C "$WORK" add -A
git -C "$WORK" -c user.email=selftest@example.invalid -c user.name=selftest commit -q -m scaffold
[ -z "$(git -C "$WORK" status --porcelain)" ] || fail "the scratch repository did not start clean"

hdr
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

# --- #2899: a companion that PASSES but leaves the tree changed is rejected.
# The observed escape: probe code appended to a tracked compiler source, the
# restore skipped, the suite reporting ok. Each shape is its own case, and each
# checks that its mutation actually landed before believing the verdict.
restore_scratch() {
  git -C "$WORK" checkout -q -- lib/source.vibe
  rm -f "$WORK/lib/stray_probe.vibe"
}

# (a) A tracked file mutated and never restored -- the #2899 residue exactly.
printf '#!/usr/bin/env bash\nprintf "\\nexport fn probe_after_quote() -> Unit {\\n  ()\\n}\\n" >> "$(dirname "$0")/../lib/source.vibe"\nexit 0\n' \
  > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that left probe code in a tracked file was accepted"; fi
grep -q probe_after_quote "$WORK/lib/source.vibe" || fail "case (a): the probe did not land -- the verdict proves nothing"
grep -q "left the working tree changed" "$WORK/out" || { cat "$WORK/out" >&2; fail "case (a): the failure did not say the tree changed"; }
grep -q "scripts/check_thing_test.sh" "$WORK/out" || { cat "$WORK/out" >&2; fail "case (a): the failure did not name the companion"; }
grep -q "lib/source.vibe" "$WORK/out" || { cat "$WORK/out" >&2; fail "case (a): the failure did not name the file"; }
echo "  ok  a passing companion that leaves a tracked file modified is rejected, by name"

# (b) An untracked file left behind.
restore_scratch
printf '#!/usr/bin/env bash\necho probe > "$(dirname "$0")/../lib/stray_probe.vibe"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that left an untracked file was accepted"; fi
[ -f "$WORK/lib/stray_probe.vibe" ] || fail "case (b): the stray file did not land"
grep -q "lib/stray_probe.vibe" "$WORK/out" || { cat "$WORK/out" >&2; fail "case (b): the failure did not name the stray file"; }
echo "  ok  a passing companion that leaves an untracked file is rejected"

# (c) A file that was ALREADY dirty before the suite, changed further. `git
# status` alone reads ` M` both times, so only the diff digest can see it --
# and that is the developer's own work being edited under them.
restore_scratch
printf '// the developer'"'"'s uncommitted edit\n' >> "$WORK/lib/source.vibe"
printf '#!/usr/bin/env bash\nprintf "// probe\\n" >> "$(dirname "$0")/../lib/source.vibe"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that edited an already-dirty file was accepted"; fi
grep -q '^// probe$' "$WORK/lib/source.vibe" || fail "case (c): the probe did not land"
grep -q "left the working tree changed" "$WORK/out" || { cat "$WORK/out" >&2; fail "case (c): the failure did not say the tree changed"; }
echo "  ok  a companion that edits an already-dirty file further is rejected"

# (d) An UNTRACKED file that existed before the suite, edited by a companion.
# Its `??` status line is the same both times and it is outside `git diff`,
# so only a content digest sees the edit (#3099 review).
restore_scratch
printf 'untracked work\n' > "$WORK/lib/stray_probe.vibe"
printf '#!/usr/bin/env bash\nprintf "probe\\n" >> "$(dirname "$0")/../lib/stray_probe.vibe"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that edited a pre-existing untracked file was accepted"; fi
grep -q '^probe$' "$WORK/lib/stray_probe.vibe" || fail "case (d): the probe did not land"
echo "  ok  a companion that edits a pre-existing untracked file is rejected"

# (e) The same, for an untracked file whose name starts with `-`: handed to
# cksum bare it reads as an option and hashes nothing (#3099 review).
restore_scratch
printf 'a\n' > "$WORK/-probe"
printf '#!/usr/bin/env bash\nprintf "b\\n" > "$(dirname "$0")/../-probe"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that edited a pre-existing untracked -dash file was accepted"; fi
rm -f -- "$WORK/-probe"
echo "  ok  a companion that edits a pre-existing untracked -dash file is rejected"

# (f) A pre-existing untracked DANGLING symlink retargeted by a companion:
# following it hashes nothing either way (#3099 review).
restore_scratch
ln -s missing-a "$WORK/lib/probe_link"
printf '#!/usr/bin/env bash\nln -sfn missing-b "$(dirname "$0")/../lib/probe_link"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
if run_exec; then cat "$WORK/out" >&2; fail "a companion that retargeted a pre-existing untracked symlink was accepted"; fi
rm -f -- "$WORK/lib/probe_link"
echo "  ok  a companion that retargets a pre-existing untracked symlink is rejected"

# ...and a pre-existing dirty tree by itself is NOT a finding: the check is
# "unchanged by the suite", not "clean", or it could never run mid-work.
restore_scratch
printf '// the developer'"'"'s uncommitted edit\n' >> "$WORK/lib/source.vibe"
printf 'untracked work\n' > "$WORK/lib/stray_probe.vibe"
printf '#!/usr/bin/env bash\nscratch="$(mktemp -d)"; echo x > "$scratch/f"; rm -rf "$scratch"\nexit 0\n' > "$WORK/scripts/check_thing_test.sh"
run_exec || { cat "$WORK/out" >&2; fail "a companion that works in a temp dir was rejected on a tree that was already dirty"; }
echo "  ok  a tree dirty BEFORE the suite, left as it was, passes"
restore_scratch


echo "[gate-self-tests-test] ok"

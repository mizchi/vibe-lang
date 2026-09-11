#!/usr/bin/env bash
# Red test for scripts/test_ci_compiler_gate_layout.sh (Codex review of #2648).
#
# CLAUDE.md #2248: a gate that passed means nothing until it is known to be able
# to fail, and red tests run by hand and written into a commit message do not
# survive the next edit. The guards added in #2648 had exactly that status:
# verified once, locally, with nothing to hold them.
#
# Every case MUTATES a copy of the real workflow and asserts the gate exits
# non-zero, and every mutation is verified to BIND IN YAML before the gate is
# asked -- an edit that lands somewhere unintended passes while proving nothing,
# which happened during #2648 (a mutation went into the compiler-build job
# instead of compiler-gate-lanes and the gate "failed" for the wrong reason).
set -euo pipefail

unset VIBE_CI_LAYOUT_WORKFLOW

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/test_ci_compiler_gate_layout.sh"
REAL="$ROOT_DIR/.github/workflows/ci.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_ci_layout_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test_ci_compiler_gate_layout_test: FAIL: $*" >&2; exit 1; }

# $1 = python source mutating the workflow at $TMP/ci.yml; it MUST assert that
# its own edit bound, so a mutation that misses is an error and not a pass.
mutate() {
  cp "$REAL" "$TMP/ci.yml"
  python3 - "$TMP/ci.yml" <<PY || fail "mutation did not bind: $2"
import sys, yaml, pathlib
path = pathlib.Path(sys.argv[1])
s = path.read_text()
$1
path.write_text(s)
doc = yaml.safe_load(path.read_text())
$3
PY
}

# The late lane the gate should read. A case that mutates it points this at a
# copy; every other case leaves it on the real file.
LATE="$ROOT_DIR/tests/gates/late/run.sh"
SELFTESTS="$ROOT_DIR/tests/gates/selftests/run.sh"

expect_reject() {  # $1 = label, $2 = substring the message must contain
  if (cd "$ROOT_DIR" && VIBE_CI_LAYOUT_WORKFLOW="$TMP/ci.yml" VIBE_CI_LAYOUT_LATE_GATE="$LATE" \
      VIBE_CI_LAYOUT_SELFTESTS_GATE="$SELFTESTS" bash "$GATE" >"$TMP/out" 2>&1); then
    cat "$TMP/out" >&2
    fail "$1: the mutated workflow was ACCEPTED"
  fi
  grep -q "$2" "$TMP/out" || { cat "$TMP/out" >&2; fail "$1: the message does not say why"; }
  echo "test_ci_compiler_gate_layout_test: ok: $1"
}

lanes_slice='i = s.index("  compiler-gate-lanes:"); j = s.index("\n  vibe-fmt-check:", i); blk = s[i:j]'

# --- control: the real workflow passes ------------------------------------
(cd "$ROOT_DIR" && bash "$GATE" >"$TMP/control.out" 2>&1) \
  || { cat "$TMP/control.out" >&2; fail "control: the repository's own workflow is rejected"; }
echo "test_ci_compiler_gate_layout_test: ok: control: the real workflow passes"

# --- cases 1-3: every spelling of the dependency on the lanes -------------
for spelling in 'needs: [compiler-build]' 'needs:\n      - compiler-build' 'needs: compiler-build'; do
  mutate "
$lanes_slice
blk = blk.replace('  compiler-gate-lanes:\n', '  compiler-gate-lanes:\n    ${spelling}\n', 1)
s = s[:i] + blk + s[j:]
" "lanes needs ($spelling)" "
lanes = doc['jobs']['compiler-gate-lanes']
needs = lanes.get('needs')
assert needs, f'needs did not bind: {needs!r}'
"
  expect_reject "a lanes dependency spelled '${spelling}' is rejected" "compiler-gate-lanes"
done

# --- case 4: a FULL revert -- only the lanes rule catches this ------------
# The symmetric uses<->needs rule accepts it, because both halves are present.
mutate "
$lanes_slice
blk = blk.replace('  compiler-gate-lanes:\n', '  compiler-gate-lanes:\n    needs:\n      - compiler-build\n', 1)
blk = blk.replace('      - name: Generated compiler artifacts (fingerprint)', '      - name: Use the compiler built once for this run\n        uses: ./.github/actions/use-compiler-build\n      - name: Generated compiler artifacts (fingerprint)', 1)
s = s[:i] + blk + s[j:]
" "full revert" "
lanes = doc['jobs']['compiler-gate-lanes']
assert lanes.get('needs') == ['compiler-build'], lanes.get('needs')
assert any(str(st.get('uses','')).strip() == './.github/actions/use-compiler-build' for st in lanes['steps']), 'uses did not bind'
"
expect_reject "a full revert (dependency AND download) is rejected" "compiler-gate-lanes declares"

# --- case 5: the lanes stop building in-job -------------------------------
mutate "
$lanes_slice
blk = blk.replace('bash scripts/generations.sh build --out-dir _build/_ci_shard_gen', 'true  # build removed', 1)
s = s[:i] + blk + s[j:]
" "build removed" "
lanes = doc['jobs']['compiler-gate-lanes']
runs = ' '.join(str(st.get('run','')) for st in lanes['steps'])
assert 'generations.sh build' not in runs, 'the build is still there'
"
expect_reject "the lanes losing their in-job build is rejected" "no longer builds stage2 in-job"

# --- case 6: PyYAML provisioned AFTER a gate that parses the workflow -----
mutate "
start = s.index('      - name: Provision PyYAML for the gates that parse the workflows')
end = s.index('      - name: architecture-debt lint self-test', start)
block = s[start:end]
s = s[:start] + s[end:]
k = s.index('      - name: pkfire pin gate self-test')
s = s[:k] + block + s[k:]
" "pyyaml misordered" "
steps = doc['jobs']['structural-lint']['steps']
prov = next(n for n, st in enumerate(steps) if 'pyyaml' in str(st.get('run','')).lower())
gate = next(n for n, st in enumerate(steps) if 'test_ci_compiler_gate_layout' in str(st.get('run','')))
assert prov > gate, f'not misordered: provision={prov} gate={gate}'
"
expect_reject "PyYAML provisioned after the gate that needs it is rejected" "before its dependency is installed"


# --- cases 7-8: the gate self-test suite must not return to the late lane ---
# The lane is the critical path and the suite is 208s of shell. The rule reads
# INVOCATIONS, not the name: the real late/run.sh carries a comment naming the
# script (that is the standing control, case 8 makes it explicit) and a gate
# that matched the name alone would fail on its own explanation.
REAL_LATE="$ROOT_DIR/tests/gates/late/run.sh"

cp "$REAL_LATE" "$TMP/late.sh"
printf '\nbash "$ROOT_DIR/scripts/check_gate_self_tests.sh"\n' >> "$TMP/late.sh"
grep -qE '^[^#]*\bbash\b[^#]*check_gate_self_tests' "$TMP/late.sh" \
  || fail "mutation did not bind: the late lane still has no invocation"
cp "$REAL" "$TMP/ci.yml"
LATE="$TMP/late.sh"
expect_reject "the late lane invoking the suite again is rejected" "invokes the gate self-test suite"

cp "$REAL_LATE" "$TMP/late_comment.sh"
printf '\n# bash "$ROOT_DIR/scripts/check_gate_self_tests.sh" -- moved, see ci.yml\n' \
  >> "$TMP/late_comment.sh"
grep -qF 'check_gate_self_tests.sh' "$TMP/late_comment.sh" \
  || fail "mutation did not bind: the comment was not added"
LATE="$TMP/late_comment.sh"
if ! (cd "$ROOT_DIR" && VIBE_CI_LAYOUT_WORKFLOW="$TMP/ci.yml" VIBE_CI_LAYOUT_LATE_GATE="$LATE" \
      VIBE_CI_LAYOUT_SELFTESTS_GATE="$SELFTESTS" bash "$GATE" >"$TMP/out" 2>&1); then
  cat "$TMP/out" >&2
  fail "a commented-out invocation was rejected -- the rule is matching the name, not the call"
fi
echo "test_ci_compiler_gate_layout_test: ok: a commented mention of the suite is not an invocation"
LATE="$REAL_LATE"

# --- case 9: the selftests lane stops invoking the suite -------------------
# "Not in the late lane" is also true of a suite that was simply deleted --
# the #2580 defect, where three gates went dark and no gate noticed.
REAL_SELFTESTS="$ROOT_DIR/tests/gates/selftests/run.sh"
cp "$REAL_SELFTESTS" "$TMP/selftests.sh"
python3 - "$TMP/selftests.sh" <<'MUT9' || fail "mutation did not bind: the invocation is still there"
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('bash "$ROOT_DIR/scripts/check_gate_self_tests.sh"', 'true  # removed', 1)
p.write_text(s)
assert not re.search(r'^[^#]*\bbash\b[^#]*check_gate_self_tests\.sh', s, re.M), "still invoked"
MUT9
cp "$REAL" "$TMP/ci.yml"
SELFTESTS="$TMP/selftests.sh"
expect_reject "the selftests lane not invoking the suite is rejected" "does not invoke check_gate_self_tests.sh"
SELFTESTS="$REAL_SELFTESTS"

# --- case 10: the workflow stops selecting the lane -----------------------
# A lane that exists but is never selected runs exactly as often as one that
# was deleted, and reads as present to anyone grepping the tree.
mutate "
s = s.replace('        lane: [early, mid, late, selftests]', '        lane: [early, mid, late]', 1)
" "lane dropped from the matrix" "
m = doc['jobs']['compiler-gate-lanes']['strategy']['matrix']['lane']
assert 'selftests' not in m, m
"
expect_reject "a workflow that never selects the selftests lane is rejected" "runs nowhere in CI"

# --- case 11: the lane runs without a YAML parser -------------------------
# check_pkfire_pin_test.sh is one of the companions and parses YAML. In the
# late lane that was met only by the hosted image happening to ship one.
mutate "
$lanes_slice
k0 = blk.index('      - name: Provision PyYAML')
k1 = blk.index('      - name: Generated compiler artifacts', k0)
step = blk[k0:k1]
blk = blk.replace(step, '', 1)
s = s[:i] + blk + s[j:]
" "pyyaml step removed" "
steps = doc['jobs']['compiler-gate-lanes']['steps']
assert not any('pyyaml' in str(st.get('run','')).lower() for st in steps), 'still provisioned'
"
expect_reject "the selftests lane running with no YAML parser is rejected" "never provisions PyYAML"

# --- case 12: the parser is provisioned, but too late ---------------------
mutate "
$lanes_slice
k0 = blk.index('      - name: Provision PyYAML')
k1 = blk.index('      - name: Generated compiler artifacts', k0)
step = blk[k0:k1]
blk = blk.replace(step, '', 1)
marker = '        run: bash scripts/compiler_gate.sh'
k = blk.index(marker) + len(marker) + 1
blk = blk[:k] + step + blk[k:]
s = s[:i] + blk + s[j:]
" "pyyaml after the lane" "
steps = doc['jobs']['compiler-gate-lanes']['steps']
prov = next(n for n, st in enumerate(steps) if 'pyyaml' in str(st.get('run','')).lower())
lane = next(n for n, st in enumerate(steps)
            if any(t.endswith('compiler_gate.sh') for t in str(st.get('run','')).split()))
assert prov > lane, f'not misordered: provision={prov} lane={lane}'
"
expect_reject "PyYAML provisioned after the selftests lane is rejected" "before its dependency is installed"
echo "test_ci_compiler_gate_layout_test: ok (control + 12 cases)"

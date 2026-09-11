#!/usr/bin/env bash
# Red test for scripts/test_ci_compiler_gate_layout.sh (Codex review of #2648).
#
# CLAUDE.md #2248: "通ったゲートは、失敗できると分かるまで何も意味しない" --- a gate
# that passed means nothing until it is known to be able to fail, and red tests
# run by hand and written into a commit message do not survive the next edit.
# The guards added in #2648 had exactly that status: verified once, locally,
# with nothing to hold them.
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

expect_reject() {  # $1 = label, $2 = substring the message must contain
  if (cd "$ROOT_DIR" && VIBE_CI_LAYOUT_WORKFLOW="$TMP/ci.yml" bash "$GATE" >"$TMP/out" 2>&1); then
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

echo "test_ci_compiler_gate_layout_test: ok (control + 6 cases)"

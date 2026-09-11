#!/usr/bin/env bash
# Red test for scripts/check_gate_lane_coverage.sh.
#
# Every case MUTATES a copy of the real tree and asserts the gate rejects it,
# and every mutation is verified to have BOUND before the gate is asked.
set -euo pipefail

unset VIBE_GATE_LANE_COVERAGE_ROOT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/check_gate_lane_coverage.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_lane_cov.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "check_gate_lane_coverage_test: FAIL: $*" >&2; exit 1; }

# A scratch tree holding only what the gate reads.
fresh() {
  rm -rf "$TMP/t"; mkdir -p "$TMP/t/tests/gates"
  cp "$ROOT_DIR/tests/gates/lib.sh" "$TMP/t/tests/gates/lib.sh"
  cp "$ROOT_DIR/Taskfile.pkl" "$TMP/t/Taskfile.pkl"
  mkdir -p "$TMP/t/.github/workflows"
  cp "$ROOT_DIR/.github/workflows/ci.yml" "$TMP/t/.github/workflows/ci.yml"
}

expect_reject() {  # $1 = label, $2 = substring the message must contain
  if VIBE_GATE_LANE_COVERAGE_ROOT="$TMP/t" bash "$GATE" >"$TMP/out" 2>&1; then
    cat "$TMP/out" >&2
    fail "$1: the mutated tree was ACCEPTED"
  fi
  grep -q "$2" "$TMP/out" || { cat "$TMP/out" >&2; fail "$1: the message does not say why"; }
  echo "check_gate_lane_coverage_test: ok: $1"
}

# --- control ---------------------------------------------------------------
fresh
VIBE_GATE_LANE_COVERAGE_ROOT="$TMP/t" bash "$GATE" >"$TMP/control.out" 2>&1 \
  || { cat "$TMP/control.out" >&2; fail "control: the repository's own tree is rejected"; }
echo "check_gate_lane_coverage_test: ok: control: the real tree passes"

# --- case 1: the defect this gate exists for -------------------------------
# A lane is added to GATE_LANES and to CI, and the Taskfile enumeration is left
# alone. That is exactly what happened to `selftests` (#2650 review).
fresh
python3 - "$TMP/t/Taskfile.pkl" <<'MUT1' || fail "mutation did not bind: the lane is still enumerated"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = 'compiler_gate.sh early mid late selftests"'
assert old in s, "the enumeration is not where the mutation expects it"
s = s.replace(old, 'compiler_gate.sh early mid late"', 1)
p.write_text(s)
assert 'compiler_gate.sh early mid late selftests' not in p.read_text(), "mutation did not land"
MUT1
expect_reject "an enumeration that omits a lane is rejected" "omits: selftests"

# --- case 2: a lane that does not exist ------------------------------------
fresh
python3 - "$TMP/t/Taskfile.pkl" <<'MUT2' || fail "mutation did not bind"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = 'compiler_gate.sh early mid late selftests"'
assert old in s
p.write_text(s.replace(old, 'compiler_gate.sh early mid late selftests typo"', 1))
MUT2
expect_reject "an enumeration naming a lane that does not exist is rejected" "do not exist: typo"

# --- case 3: the scan matching NOTHING must not pass -----------------------
# Silence and "no enumeration exists" are the same output, and only one of
# them is a pass. This is the failure mode that let #2580's gates go dark.
fresh
python3 - "$TMP/t/Taskfile.pkl" <<'MUT3' || fail "mutation did not bind: an enumeration remains"
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace('compiler_gate.sh early mid late selftests"', 'compiler_gate.sh"', 1)
p.write_text(s)
# Mirror the gate's predicate: a match counts only when the trailing words
# are LANE names. Prose ("// compiler_gate.sh runs it up front") is not an
# enumeration, and asserting on the bare regex would fail on it.
lanes = set(pathlib.Path(sys.argv[1]).parent.joinpath("tests/gates/lib.sh").read_text()
            .split('GATE_LANES="')[1].split('"')[0].split())
for line in p.read_text().splitlines():
    if line.lstrip().startswith("//"):
        continue
    m = re.search(r'compiler_gate\.sh((?:[ \t]+[a-z][a-z0-9_-]*)+)', line)
    assert not (m and set(m.group(1).split()) & lanes), f"still enumerates: {line.strip()}"
MUT3
expect_reject "a tree with no enumeration at all is rejected, not passed vacuously" "matched nothing"

# --- case 4: GATE_LANES unreadable -----------------------------------------
fresh
python3 - "$TMP/t/tests/gates/lib.sh" <<'MUT4' || fail "mutation did not bind"
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s2 = re.sub(r'^GATE_LANES="[^"]*"', '# GATE_LANES removed', s, count=1, flags=re.M)
assert s2 != s, "GATE_LANES was not where the mutation expects it"
p.write_text(s2)
MUT4
expect_reject "a tree with no GATE_LANES is rejected" "no GATE_LANES assignment"

# --- case 5: the WORKFLOW enumerates lanes and omits one -------------------
# The reverse of case 1, and the reason this gate reads more than the Taskfile:
# a workflow step edited to `compiler_gate.sh early mid late` drops the lane
# from CI itself, where the Taskfile is untouched and case 1 stays green
# (#2650 review).
fresh
python3 - "$TMP/t/.github/workflows/ci.yml" <<'MUT5' || fail "mutation did not bind: the workflow does not enumerate lanes"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "        run: bash scripts/compiler_gate.sh\n"
assert old in s, "the lane step is not where the mutation expects it"
p.write_text(s.replace(old, "        run: bash scripts/compiler_gate.sh early mid late\n", 1))
assert "compiler_gate.sh early mid late" in p.read_text(), "mutation did not land"
MUT5
expect_reject "a workflow enumeration that omits a lane is rejected" "omits: selftests"

echo "check_gate_lane_coverage_test: ok (control + 5 cases)"

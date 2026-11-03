#!/usr/bin/env bash
# Red/green for scripts/check_gate_registry.vibex (#2001 Phase 0; #3672 ported
# the gate).
#
# Every red case mutates a COPY of tests/gates under _build/ (the gate reads
# only inside the repository) and runs the gate on it with --root, so nothing
# here edits the live lanes. The copy's fixtures/ is a link to the real one, so
# the fixtures the lanes name exist there too. Each mutation is checked to
# have landed before its verdict is believed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_REL="_build/gate_registry_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
OUT="$WORK/out"

fail=0
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_gate_registry.vibex -- "$@"; }
assert_ok() {
  local label="$1"; shift
  if ! "$@" >"$OUT" 2>&1; then
    echo "FAIL: expected ok: $label" >&2
    cat "$OUT" >&2
    fail=1
  fi
}

assert_fails() {
  local label="$1"; shift
  if "$@" >"$OUT" 2>&1; then
    echo "FAIL: expected fail: $label" >&2
    cat "$OUT" >&2
    fail=1
  fi
}

assert_contains() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$OUT"; then
    echo "FAIL: output missing '$needle'" >&2
    cat "$OUT" >&2
    fail=1
  fi
}

landed() { # landed <file> <fixed string> <case>
  grep -qF -- "$2" "$1" || { echo "FAIL: $3: the mutation did not land" >&2; fail=1; }
}

tree="$WORK/tree"
reset_tree() {
  rm -rf "$tree"
  mkdir -p "$tree/tests"
  cp -R tests/gates "$tree/tests/gates"
  ln -s ../../../fixtures "$tree/fixtures"
}
red() { # red <case> <expected message>
  assert_fails "$1" gate --root "$WORK_REL/tree"
  assert_contains "$2"
}

# The committed registry + lanes must themselves be clean.
assert_ok "live registry" gate

# --list is non-empty and names bootstrap.
assert_ok "list" gate --list
assert_contains $'\tbootstrap\t'

# Dispatcher --list names every coarse lane.
assert_ok "dispatcher list" bash scripts/compiler_gate.sh --list
assert_contains bootstrap
assert_contains early
assert_contains mid
assert_contains late

# Unknown lane is a usage error, not a silent all-lanes run.
assert_fails "unknown lane" env COMPILER_GATE_LANE=nope bash scripts/compiler_gate.sh
assert_contains "unknown lane"

# The unmutated copy passes, or every red case below proves nothing.
reset_tree
assert_ok "unmutated copy" gate --root "$WORK_REL/tree"

# Duplicate id is rejected -- by the gate itself, on a copy of the registry.
reset_tree
printf 'dup-id\tbootstrap\t0/3 builtin parity (#415 B-3)\n' >> "$tree/tests/gates/registry.tsv"
printf 'dup-id\tearly\t4/4 multi-file FS-compile regression\n' >> "$tree/tests/gates/registry.tsv"
red "duplicate id" "duplicate id 'dup-id'"

# A row naming a lane that does not exist.
reset_tree
printf 'ghost-row\tnowhere\tsome section\n' >> "$tree/tests/gates/registry.tsv"
red "unknown lane in a row" "id 'ghost-row' names unknown lane 'nowhere'"

# A row with no title.
reset_tree
printf 'half-row\tearly\n' >> "$tree/tests/gates/registry.tsv"
red "malformed row" "malformed row: id='half-row' lane='early'"

# A row whose title no source of its lane announces.
reset_tree
printf 'stale-row\tearly\tthis section was deleted long ago\n' >> "$tree/tests/gates/registry.tsv"
red "title not in the lane" "id 'stale-row' title not found in lane 'early' sources"

# A section banner with no registry row.
reset_tree
printf 'echo "[compiler-gate] an unregistered section nobody owns"\n' >> "$tree/tests/gates/early/run.sh"
landed "$tree/tests/gates/early/run.sh" 'an unregistered section nobody owns' "unregistered banner"
red "unregistered banner" "announces unregistered section: an unregistered section nobody owns"

# ...while a success banner needs no row.
reset_tree
printf 'echo "[compiler-gate] early lane ok (all sections)"\n' >> "$tree/tests/gates/early/run.sh"
assert_ok "a success banner needs no row" gate --root "$WORK_REL/tree"

# A lane naming a fixture that does not exist.
reset_tree
printf 'probe="fixtures/no_such_fixture_for_the_registry_test.vibe"\n' >> "$tree/tests/gates/early/run.sh"
red "missing fixture" "names missing fixture fixtures/no_such_fixture_for_the_registry_test.vibe"

# ...the same path passed to gate_fs_compile (tests/gates/lib.sh) is a
# reference too...
reset_tree
printf 'gate_fs_compile "fixtures/no_such_fixture_for_the_registry_test.vibe" "$d/out.wasm" main\n' >> "$tree/tests/gates/early/run.sh"
red "missing fixture in a compile" "names missing fixture fixtures/no_such_fixture_for_the_registry_test.vibe"

# ...but the MESSAGE of a gate_require_artifact line is prose, the lane's words
# for what failed, as it was inside an `echo "[compiler-gate] FAIL: ..."`.
reset_tree
printf 'gate_require_artifact "$d/out.wasm" "fixtures/no_such_fixture_for_the_registry_test.vibe did not compile"\n' >> "$tree/tests/gates/early/run.sh"
landed "$tree/tests/gates/early/run.sh" 'did not compile' "require message"
assert_ok "a gate_require_artifact message is not a fixture reference" gate --root "$WORK_REL/tree"

# #2107 fallout: a compile whose failure the lane checks must not be able to
# abort the lane before the check. Red case built by REMOVING the guard from a
# live step, so the test breaks if the rule stops being enforced rather than if
# some synthetic sample drifts.
reset_tree
lane_copy="$tree/tests/gates/mid/retired_v128_intrinsics_stay_retired.sh"
python3 - "$lane_copy" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '"$vdir/retired_v128.vibe" "$vdir/v128.wasm" __no_entry__ >"$vdir/out.txt" 2>&1 || true'
assert s.count(old) == 1, "the guarded step this Red case removes has moved"
open(p, 'w').write(s.replace(old, old[:-len(" || true")], 1))
PYEOF
landed "$lane_copy" '__no_entry__ >"$vdir/out.txt" 2>&1' "unguarded compile"
red "unguarded compile-then-check" "add \`|| true\`"

# No lanes read is not a clean registry.
reset_tree
grep -v '^GATE_LANES=' "$ROOT_DIR/tests/gates/lib.sh" > "$tree/tests/gates/lib.sh"
if grep -q '^GATE_LANES=' "$tree/tests/gates/lib.sh"; then echo "FAIL: no lanes: the mutation did not land" >&2; fail=1; fi
red "no GATE_LANES" "has no GATE_LANES"

# A registry that is not there.
reset_tree
rm "$tree/tests/gates/registry.tsv"
red "missing registry" "missing tests/gates/registry.tsv"

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ok check_gate_registry_test"

#!/usr/bin/env bash
# Red/green for scripts/check_gate_registry.sh (#2001 Phase 0).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail=0
assert_ok() {
  local label="$1"; shift
  if ! "$@" >/tmp/gate_registry_test.out 2>&1; then
    echo "FAIL: expected ok: $label" >&2
    cat /tmp/gate_registry_test.out >&2
    fail=1
  fi
}

assert_fails() {
  local label="$1"; shift
  if "$@" >/tmp/gate_registry_test.out 2>&1; then
    echo "FAIL: expected fail: $label" >&2
    cat /tmp/gate_registry_test.out >&2
    fail=1
  fi
}

assert_contains() {
  local needle="$1"
  if ! grep -qF "$needle" /tmp/gate_registry_test.out; then
    echo "FAIL: output missing '$needle'" >&2
    cat /tmp/gate_registry_test.out >&2
    fail=1
  fi
}

# The committed registry + lanes must themselves be clean.
assert_ok "live registry" bash scripts/check_gate_registry.sh

# --list is non-empty and names bootstrap.
assert_ok "list" bash scripts/check_gate_registry.sh --list
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

# Duplicate id is rejected. Work in a copy of the tree's registry by
# pointing the checker at a swapped file via a tiny wrapper.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp tests/gates/registry.tsv "$tmp/registry.tsv"
printf 'dup-id\tbootstrap\t0/3 builtin parity (#415 B-3)\n' >> "$tmp/registry.tsv"
printf 'dup-id\tearly\t4/4 multi-file FS-compile regression\n' >> "$tmp/registry.tsv"
# The checker hardcodes the path; exercise the same rules with a one-off.
if awk -F'\t' '
  $1 ~ /^#/ || $1 == "" || $1 == "id" { next }
  seen[$1]++ { exit 1 }
' "$tmp/registry.tsv"; then
  echo "FAIL: duplicate-id awk did not reject" >&2
  fail=1
fi

# #2107 fallout: a compile whose failure the lane checks must not be able to
# abort the lane before the check. Red case built by REMOVING the guard from a
# live step, so the test breaks if the rule stops being enforced rather than if
# some synthetic sample drifts.
lanecopy="$tmp/mid_run.sh"
cp tests/gates/mid/run.sh "$lanecopy"
python3 - "$lanecopy" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '"$vdir/retired_v128.vibe" "$vdir/v128.wasm" __no_entry__ >"$vdir/out.txt" 2>&1 || true'
assert s.count(old) == 1, "the guarded step this Red case removes has moved"
open(p, 'w').write(s.replace(old, old[:-len(" || true")], 1))
PYEOF
cp tests/gates/mid/run.sh "$tmp/mid_run.orig.sh"
cp "$lanecopy" tests/gates/mid/run.sh
set +e
bash scripts/check_gate_registry.sh >/tmp/gate_registry_test.out 2>&1
unguarded_rc=$?
set -e
cp "$tmp/mid_run.orig.sh" tests/gates/mid/run.sh
if [ "$unguarded_rc" -eq 0 ]; then
  echo "FAIL: an unguarded compile-then-check step was accepted" >&2
  fail=1
else
  assert_contains "add \`|| true\`"
fi

# ...and the restored tree is clean again, so the Red case left nothing behind.
assert_ok "restored lane" bash scripts/check_gate_registry.sh

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ok check_gate_registry_test"

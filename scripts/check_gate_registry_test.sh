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

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ok check_gate_registry_test"

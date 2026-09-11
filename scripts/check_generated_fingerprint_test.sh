#!/usr/bin/env bash
# Red test for scripts/check_generated_fingerprint.sh.
#
# Each case MUTATES a copy of the real scripts/ensure_generated.sh and asserts
# the gate rejects it, and each mutation is verified to have BOUND before the
# gate is asked -- an edit that lands somewhere unintended passes while proving
# nothing.
set -euo pipefail

unset VIBE_GENERATED_FINGERPRINT_SCRIPT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/check_generated_fingerprint.sh"
REAL="$SCRIPT_DIR/ensure_generated.sh"
# The probe must be a SIBLING of the real script, not a copy in a temp dir:
# ensure_generated.sh resolves its own SCRIPT_DIR and runs ensure_seed.sh from
# it, so a copy anywhere else dies on a missing sibling before it can compute
# anything -- which the gate correctly reports as a failure, for the wrong
# reason. Dot-prefixed so no `check_*` / `lint_*` glob can pick it up.
PROBE="$SCRIPT_DIR/.fpcheck_probe_$$.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vibe_fpcheck.XXXXXX")"
trap 'rm -rf "$TMP" "$PROBE"' EXIT

fail() { echo "check_generated_fingerprint_test: FAIL: $*" >&2; exit 1; }

expect_reject() {  # $1 = label, $2 = substring the message must contain
  if (cd "$ROOT_DIR" && VIBE_GENERATED_FINGERPRINT_SCRIPT="$PROBE" \
      bash "$GATE" >"$TMP/out" 2>&1); then
    cat "$TMP/out" >&2
    fail "$1: the mutated script was ACCEPTED"
  fi
  grep -q "$2" "$TMP/out" || { cat "$TMP/out" >&2; fail "$1: the message does not say why"; }
  echo "check_generated_fingerprint_test: ok: $1"
}

# --- control: the real script passes --------------------------------------
(cd "$ROOT_DIR" && bash "$GATE" >"$TMP/control.out" 2>&1) \
  || { cat "$TMP/control.out" >&2; fail "control: the repository's own script is rejected"; }
echo "check_generated_fingerprint_test: ok: control: the real script passes"

# --- case 1: the historical defect, restored ------------------------------
# `sha256sum FILE` prints the path it was given, so hashing "${BASH_SOURCE[0]}"
# puts the caller's spelling into the fingerprint. This is the exact line the
# fix replaced, and it cost 128s and 131s in two CI jobs on run 34590373673.
cp "$REAL" "$PROBE"
python3 - "$PROBE" <<'MUT1' || fail "mutation did not bind: the BASH_SOURCE spelling is not present"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '    hash_as "${BASH_SOURCE[0]}" scripts/ensure_generated.sh\n'
assert old in s, "the fixed line is not where the mutation expects it"
s = s.replace(old, '    sha256sum "${BASH_SOURCE[0]}" 2>/dev/null || echo "MISSING"\n', 1)
p.write_text(s)
assert 'sha256sum "${BASH_SOURCE[0]}"' in p.read_text(), "mutation did not land"
MUT1
expect_reject "a fingerprint line that records the caller's spelling is rejected" \
  "depends on how the script was called"

# --- case 2: an empty answer must not pass vacuously ----------------------
# Two empty strings compare equal. A gate that only asks "are they the same?"
# reports ok forever once --print-fingerprint stops printing.
cp "$REAL" "$PROBE"
python3 - "$PROBE" <<'MUT2' || fail "mutation did not bind: --print-fingerprint still prints"
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '  printf \'%s\\n\' "$FP"'
assert old in s, "the FP print line is not where the mutation expects it"
s = s.replace(old, "  true  # print removed", 1)
p.write_text(s)
MUT2
out="$(cd "$ROOT_DIR" && bash "$PROBE" --print-fingerprint 2>/dev/null || true)"
[ -z "$out" ] || fail "mutation did not bind: --print-fingerprint still printed '$out'"
expect_reject "an empty fingerprint is rejected rather than compared to itself" \
  "produced nothing"

# --- case 3: a script that is not there ------------------------------------
rm -f "$PROBE"
expect_reject "a missing script is rejected" "no such script"

echo "check_generated_fingerprint_test: ok (control + 3 cases)"

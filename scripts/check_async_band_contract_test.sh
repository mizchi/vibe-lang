#!/usr/bin/env bash
# Red test for scripts/check_async_band_contract.sh (#2832).
#
# Every case mutates a scratch copy of a real source and asserts the gate
# FAILS. Each mutation is first proven to have LANDED -- an edit that matches
# nothing would let a case "pass" while measuring nothing, which is the exact
# way five gate self-tests in this repo were green about a hijackable tree
# (#2248).
#
# The gate's inputs come from env vars, so this file unsets them first: a
# self-test that inherits its subject's configuration tests the environment,
# not the gate (#2252).
set -euo pipefail

unset ASYNC_BAND_COMPONENT_CODEGEN ASYNC_BAND_LINKED_COMPILE

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GATE="scripts/check_async_band_contract.sh"
CC_REAL="lib/@vibe/compiler/entry/source_compile/wasi_only/component_codegen.vibe"
LC_REAL="lib/@vibe/compiler/codegen/wasi/linked_compile.vibe"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok() { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }

# Rewrite the body of a bare Int constant function in a scratch copy.
# $1 src  $2 dst  $3 fn name  $4 new value
mutate_const() {
  awk -v want="$3" -v val="$4" '
    { print_line = 1 }
    grab == 1 {
      line = $0
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line ~ /^-?[0-9]+$/) { print "  " val; grab = 0; print_line = 0 }
    }
    $0 ~ ("^fn " want "\\(\\) -> Int \\{") { grab = 1 }
    print_line == 1 { print }
  ' "$1" > "$2"
}

# Assert a scratch file really differs from its original, then run the gate
# against it and require a non-zero exit.
expect_fail() {
  label="$1"; cc="$2"; lc="$3"; orig_cc="$4"; orig_lc="$5"
  if cmp -s "$cc" "$orig_cc" && cmp -s "$lc" "$orig_lc"; then
    bad "$label -- the mutation is a NO-OP, so this case proves nothing"
    return
  fi
  if ASYNC_BAND_COMPONENT_CODEGEN="$cc" ASYNC_BAND_LINKED_COMPILE="$lc" \
      bash "$GATE" >"$WORK/out" 2>&1; then
    bad "$label -- gate PASSED on a broken tree"
    sed -n '1,4p' "$WORK/out" >&2
  else
    ok "$label"
  fi
}

# --- control: the real tree must pass, or every red case below is vacuous ---
if bash "$GATE" >"$WORK/green" 2>&1; then
  ok "the unmutated tree passes"
else
  bad "the unmutated tree FAILS -- fix that before trusting any case below"
  cat "$WORK/green" >&2
fi

# --- 1. a packed adjacency broken by four bytes ---
mutate_const "$CC_REAL" "$WORK/cc1.vibe" comp_hf_state_base 8196
expect_fail "a slot base off by 4 is rejected" "$WORK/cc1.vibe" "$LC_REAL" "$CC_REAL" "$LC_REAL"

# --- 2. the LAST adjacency, so the check is not just testing the first ---
mutate_const "$CC_REAL" "$WORK/cc2.vibe" comp_hs_closed_base 16388
expect_fail "the last slot adjacency is checked too" "$WORK/cc2.vibe" "$LC_REAL" "$CC_REAL" "$LC_REAL"

# --- 3. the CROSS-FILE invariant: a cap that runs the future band into the
#        stream band. This is the one no single-file reader could catch. ---
mutate_const "$CC_REAL" "$WORK/cc3.vibe" comp_hf_max_handles 4000
expect_fail "a handle cap that collides with the stream band is rejected" \
  "$WORK/cc3.vibe" "$LC_REAL" "$CC_REAL" "$LC_REAL"

# --- 4. the same invariant broken from the OTHER file, to prove the gate
#        reads both rather than hard-coding 2048. ---
mutate_const "$LC_REAL" "$WORK/lc4.vibe" lc_hs_req_base 512
expect_fail "lowering lc_hs_req_base into the future band is rejected" \
  "$CC_REAL" "$WORK/lc4.vibe" "$CC_REAL" "$LC_REAL"

# --- 5. an unreadable constant must FAIL, not skip. Silence and safety are
#        indistinguishable, and the gate exists because nobody was looking. ---
sed 's/^fn comp_hf_max_handles() -> Int {/fn comp_hf_handle_cap() -> Int {/' \
  "$CC_REAL" > "$WORK/cc5.vibe"
expect_fail "a renamed constant fails rather than silently skipping" \
  "$WORK/cc5.vibe" "$LC_REAL" "$CC_REAL" "$LC_REAL"

# --- 6. a missing source file must FAIL too ---
if ASYNC_BAND_COMPONENT_CODEGEN="$WORK/does_not_exist.vibe" \
    bash "$GATE" >"$WORK/out6" 2>&1; then
  bad "a missing source PASSED"
else
  ok "a missing source fails"
fi

echo "----"
echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]

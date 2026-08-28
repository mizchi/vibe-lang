#!/usr/bin/env bash
# Red tests for scripts/check_builtin_shadowing.sh. A gate that has never been
# shown to fail proves nothing (CLAUDE.md, #2248), so every case here mutates
# real input and asserts the gate REJECTS it -- and each red case is paired
# with the unmutated control, so a failure is attributable to the mutation and
# not to the harness.
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# The gate reads these; a value inherited from a shell profile or a
# session-start hook would silently change what is under test (#2252).
unset VIBE_SHADOW_LIB_ROOT VIBE_SHADOW_ALLOWLIST || true

GATE="scripts/check_builtin_shadowing.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0
note() { echo "[shadow-gate-test] $*"; }
bad() { echo "[shadow-gate-test] FAIL: $*" >&2; fail=$((fail + 1)); }

run_gate() {
  # $1 lib root, $2 allowlist; captures stdout+stderr in $out, status in $rc
  set +e
  out="$(VIBE_SHADOW_LIB_ROOT="$1" VIBE_SHADOW_ALLOWLIST="$2" bash "$GATE" 2>&1)"
  rc=$?
  set -e
}

# --- Case 0: the real tree passes -----------------------------------------
run_gate "lib" "scripts/builtin_shadowing_allowlist.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 0: the committed tree should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 0 ok: committed tree passes"
fi

# --- Case 1: a NEW shadow is rejected --------------------------------------
# Control first: a lib root with one non-shadowing definition, empty allowlist.
mkdir -p "$tmp/lib1/pkg"
cat > "$tmp/lib1/pkg/ok.vibe" <<'VEOF'
export fn totally_unrelated_helper(n: Int) -> Int {
  n + 1
}
VEOF
: > "$tmp/empty_allow.txt"
run_gate "$tmp/lib1" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 1 control: a lib root with no shadow should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 1 control ok: no shadow, no finding"
fi

# The mutation: add a definition of a name the registry owns.
cat > "$tmp/lib1/pkg/shadow.vibe" <<'VEOF'
export fn String::index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
run_gate "$tmp/lib1" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 1: a new String::index_of definition was NOT rejected"
elif ! printf '%s\n' "$out" | grep -q 'replace a builtin program-wide'; then
  bad "case 1: rejected, but not for the shadowing reason:"
  echo "$out" | sed 's/^/    /' >&2
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 1: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 1 ok: new shadow rejected and named"
fi

# --- Case 2: allowlisting that same definition makes it pass ---------------
# Proves the allowlist is actually consulted, not merely present.
echo "$tmp/lib1/pkg/shadow.vibe String::index_of fn" > "$tmp/allow_one.txt"
run_gate "$tmp/lib1" "$tmp/allow_one.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 2: an allowlisted shadow should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 2 ok: allowlist suppresses the known entry"
fi

# --- Case 3: a stale allowlist entry is rejected ---------------------------
printf '%s\n' "$tmp/lib1/pkg/shadow.vibe String::index_of fn" \
              "lib/@vibe/nowhere/gone.vibe String::split fn" > "$tmp/allow_stale.txt"
run_gate "$tmp/lib1" "$tmp/allow_stale.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 3: a stale allowlist entry was NOT rejected"
elif ! printf '%s\n' "$out" | grep -q 'no longer exist'; then
  bad "case 3: rejected, but not for the stale reason:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 3 ok: stale allowlist entry rejected"
fi

# --- Case 4: an empty corpus is refused, not silently passed ---------------
mkdir -p "$tmp/lib_empty"
run_gate "$tmp/lib_empty" "$tmp/empty_allow.txt"
if [ "$rc" -ne 2 ]; then
  bad "case 4: an empty lib root should exit 2, got $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 4 ok: empty corpus refused"
fi

# --- Case 5: a shadow of a DIFFERENT builtin is caught too -----------------
# Guards against a hard-coded list of the names this PR happened to remove.
cat > "$tmp/lib1/pkg/shadow2.vibe" <<'VEOF'
export fn Array::length(xs: Array[Int]) -> Int {
  0
}
VEOF
run_gate "$tmp/lib1" "$tmp/allow_one.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 5: a new Array::length definition was NOT rejected"
elif ! printf '%s\n' "$out" | grep -q 'Array::length'; then
  bad "case 5: the finding does not name Array::length:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 5 ok: a second, unrelated builtin name is caught"
fi

# --- Case 6: a declaration that FOLLOWS a closer on the same line ------------
# `} fn collect_...` and `] let parse_...` both occur in lib/. An anchored
# ^(export )?fn regex misses them in silence.
mkdir -p "$tmp/lib6/pkg"
cat > "$tmp/lib6/pkg/ok.vibe" <<'VEOF'
export fn totally_unrelated_helper(n: Int) -> Int {
  n + 1
}
VEOF
run_gate "$tmp/lib6" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 6 control: a lib root with no shadow should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 6 control ok"
fi
cat > "$tmp/lib6/pkg/closer.vibe" <<'VEOF'
export fn wrapper() -> Int {
  1
} fn String::last_index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
run_gate "$tmp/lib6" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 6: a declaration after a closing brace was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::last_index_of'; then
  bad "case 6: the finding does not name String::last_index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 6 ok: declaration after a closer is caught"
fi

# --- Case 7: a VALUE alias binds the name too -------------------------------
# lib/@vibe/fs/fs.vibe uses `export let Fs::exists = exists` deliberately; the
# ratchet has to see the form so a later conversion to a fn is visible.
mkdir -p "$tmp/lib7/pkg"
cat > "$tmp/lib7/pkg/alias.vibe" <<'VEOF'
fn my_impl(s: String, sub: String) -> Bool {
  false
}

export let String::contains = my_impl
VEOF
run_gate "$tmp/lib7" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 7: a value-alias shadow was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::contains let'; then
  bad "case 7: the finding does not record the let form:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 7 ok: value alias caught and recorded as let"
fi

# --- Case 8: an unclassifiable column-0 line FAILS, it is not skipped -------
# A lexical scan that skips what it cannot read is indistinguishable from a
# clean tree, so the scanner must stop instead (#2248).
mkdir -p "$tmp/lib8/pkg"
cat > "$tmp/lib8/pkg/weird.vibe" <<'VEOF'
export fn ordinary() -> Int {
  1
}

gizmo Whatsit {
  x: Int
}
VEOF
run_gate "$tmp/lib8" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 8: an unknown column-0 declaration keyword was silently skipped"
elif ! printf '%s\n' "$out" | grep -q 'could not classify'; then
  bad "case 8: rejected, but not for the unreadable reason:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 8 ok: unclassifiable line stops the gate"
fi

if [ "$fail" -ne 0 ]; then
  echo "[shadow-gate-test] $fail case(s) failed" >&2
  exit 1
fi
echo "[shadow-gate-test] all cases passed"

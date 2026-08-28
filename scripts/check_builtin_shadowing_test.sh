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
  # $1 lib root, $2 file standing in for the gate's pinned exemption set
  set +e
  out="$(VIBE_SHADOW_LIB_ROOT="$1" VIBE_SHADOW_ALLOWLIST="$2" bash "$GATE" 2>&1)"
  rc=$?
  set -e
}

# --- Case 0: the real tree passes -----------------------------------------
# No override: the gate uses its own pinned set, which is what case 0 tests.
set +e
out="$(VIBE_SHADOW_LIB_ROOT=lib bash "$GATE" 2>&1)"
rc=$?
set -e
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

# --- Case 8: top level is brace depth, not column zero ---------------------
# The scan used to key on column 0 and needed scaffolding (classify the head,
# refuse what it could not read) to stay honest about it. Depth is the property
# itself, and both directions of the proxy were wrong: an attribute pushed the
# declaration off column 0, and a local binding inside a one-line body was
# reported as a program-wide override.
mkdir -p "$tmp/lib8/pkg"

# (a) an attribute in front must not hide the declaration behind it
cat > "$tmp/lib8/pkg/attr.vibe" <<'VEOF'
#deprecated fn String::index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
run_gate "$tmp/lib8" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 8a: a declaration behind an attribute was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 8a: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 8a ok: an attribute does not hide the declaration"
fi

# (b) a LOCAL binding inside a body shadows nothing and must not be reported
rm "$tmp/lib8/pkg/attr.vibe"
cat > "$tmp/lib8/pkg/local.vibe" <<'VEOF'
fn ordinary() -> Int { let println = 1; println }

fn multi() -> Int {
  let eq = 2
  let String::split = 3
  eq + String::split
}
VEOF
run_gate "$tmp/lib8" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 8b: a local binding inside a function body was reported as a shadow"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 8b ok: bindings inside a body are local, not shadows"
fi

# --- Case 9: EVERY declaration on a shared line, not just the first ---------
# lib/@vibe/compiler/loader/loader.vibe:1217 is
# `] let a: Array[String] = [] fn vpkg_types_registry_note(...) {` -- three
# declarations on one line. A classifier that records the head and moves on
# misses the rest in silence, which is the failure it exists to prevent.
mkdir -p "$tmp/lib9/pkg"
cat > "$tmp/lib9/pkg/ok.vibe" <<'VEOF'
export fn totally_unrelated_helper(n: Int) -> Int {
  n + 1
}
VEOF
run_gate "$tmp/lib9" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 9 control: a lib root with no shadow should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 9 control ok"
fi
cat > "$tmp/lib9/pkg/shared.vibe" <<'VEOF'
let harmless: Array[String] = [] fn String::index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
run_gate "$tmp/lib9" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 9: a shadow trailing another declaration on the same line was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 9: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 9 ok: every declaration on a shared line is scanned"
fi

# --- Case 10: a shadow trailing a NON-declaration head ----------------------
mkdir -p "$tmp/lib10/pkg"
cat > "$tmp/lib10/pkg/after_test.vibe" <<'VEOF'
test "something" {
  1
} fn String::contains(s: String, sub: String) -> Bool {
  false
}
VEOF
run_gate "$tmp/lib10" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 10: a shadow after a non-declaration head was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::contains'; then
  bad "case 10: the finding does not name String::contains:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 10 ok: a shadow trailing a closed test block is caught"
fi

# --- Case 11: a swap cannot manufacture exemption capacity -----------------
# The count-based pin this replaced was a proxy: drop one legacy row, add a row
# for a NEW shadow, and the count is unchanged, `new` and `stale` are both
# empty, and the gate passes. Pinning IDENTITIES is what closes it -- reusing a
# retired slot now leaves the new shadow unexempted.
mkdir -p "$tmp/lib11/pkg"
cat > "$tmp/lib11/pkg/legacy.vibe" <<'VEOF'
export fn String::trim(s: String) -> String {
  s
}
VEOF
echo "$tmp/lib11/pkg/legacy.vibe String::trim fn" > "$tmp/allow_legacy.txt"
run_gate "$tmp/lib11" "$tmp/allow_legacy.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 11 control: one exempted legacy shadow should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 11 control ok: the legacy exemption holds"
fi

# The swap: retire the legacy shadow, introduce a different one, reuse the slot.
rm "$tmp/lib11/pkg/legacy.vibe"
cat > "$tmp/lib11/pkg/fresh.vibe" <<'VEOF'
export fn String::split(s: String, sep: String) -> Array[String] {
  []
}
VEOF
echo "$tmp/lib11/pkg/fresh.vibe String::split fn" > "$tmp/allow_swapped.txt"
# The set the gate is pinned to is still the legacy one.
run_gate "$tmp/lib11" "$tmp/allow_legacy.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 11: a new shadow reusing a retired exemption slot was accepted"
elif ! printf '%s\n' "$out" | grep -q 'String::split'; then
  bad "case 11: the finding does not name String::split:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 11 ok: a retired slot does not exempt a different shadow"
fi


# --- Case 12: strings and comments are not declarations --------------------
# The scan matches raw characters, so without stripping lexical trivia a line
# like `let diagnostic = "write fn String::index_of ..."` is reported as a
# program-wide override -- a false FAIL on a required gate, from a file that
# declares only `diagnostic`.
mkdir -p "$tmp/lib12/pkg"
cat > "$tmp/lib12/pkg/trivia.vibe" <<'VEOF'
let diagnostic = "write fn String::index_of to override it"

export fn ordinary(n: Int) -> Int {
  n + 1
}

// a comment mentioning fn String::split must not count either
let other = 1 // trailing: let String::contains
VEOF
run_gate "$tmp/lib12" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 12: a builtin name inside a string or comment was reported as a shadow"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 12 ok: strings and comments do not declare anything"
fi

# The other direction: stripping trivia must not blind the scan to a real
# declaration that shares the line with a string.
cat >> "$tmp/lib12/pkg/trivia.vibe" <<'VEOF'

let note = "harmless" fn String::last_index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
run_gate "$tmp/lib12" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 12b: a real shadow sharing a line with a string was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::last_index_of'; then
  bad "case 12b: the finding does not name String::last_index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 12b ok: a declaration after a string is still caught"
fi

# --- Case 13: a character literal is not a string opener -------------------
# `Char` is a real type and `let quote = \x27"\x27` is valid source. A bare quote
# scan mistakes that `"` for a string opener and swallows the rest of the line,
# so a declaration sharing it disappears -- the gate answered `ok`.
mkdir -p "$tmp/lib13/pkg"
# A quoted heredoc, so the apostrophes land literally. `printf '%s' "\x27"`
# writes the four characters, not a quote -- the red test caught that on its
# first run, which is the point of asserting the mutation landed.
cat > "$tmp/lib13/pkg/charlit.vibe" <<'VEOF'
let quote = '"' fn String::index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
if ! grep -q "fn String::index_of" "$tmp/lib13/pkg/charlit.vibe"; then
  bad "case 13: the fixture does not contain the declaration it is testing"
fi
run_gate "$tmp/lib13" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 13: a shadow after a char literal containing a quote was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 13: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 13 ok: a char literal does not swallow the line"
fi

# An apostrophe in ordinary positions must not start a char literal that eats
# the rest of the file\x27s meaning either.
cat > "$tmp/lib13/pkg/charlit.vibe" <<'VEOF'
let tick = 'x'
let msg = "it's fine"

export fn ordinary(n: Int) -> Int {
  n + 1
} // don't write fn String::split here
VEOF
run_gate "$tmp/lib13" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 13b: ordinary apostrophes produced a finding"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 13b ok: apostrophes in char literals, strings and comments are inert"
fi

# --- Case 14: interpolation nests, so strings nest -------------------------
# `"a \{tag("b")} c"` is one string containing an expression containing
# another string. A flat in-string flag mis-tracks it in BOTH directions, and
# both were reproduced on source `vibe check` accepts.
mkdir -p "$tmp/lib14/pkg"

# (a) false positive: a builtin name inside the INNER string.
cat > "$tmp/lib14/pkg/interp.vibe" <<'VEOF'
fn tag(s: String) -> String {
  s
}

let msg = "a \{tag("write fn String::split here")} c"
VEOF
run_gate "$tmp/lib14" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 14a: a builtin name inside an interpolated string was reported as a shadow"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 14a ok: an interpolated string declares nothing"
fi

# (b) the miss: a real declaration AFTER such a string.
cat > "$tmp/lib14/pkg/interp.vibe" <<'VEOF'
fn tag(s: String) -> String {
  s
}

let msg = "a \{tag("b")} c" fn String::index_of(s: String, sub: String) -> Int {
  -1
}
VEOF
if ! grep -q "fn String::index_of" "$tmp/lib14/pkg/interp.vibe"; then
  bad "case 14b: the fixture does not contain the declaration it is testing"
fi
run_gate "$tmp/lib14" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 14b: a shadow after an interpolated string was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 14b: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 14b ok: a declaration after an interpolated string is caught"
fi

# --- Case 15: depth drift is reported, not absorbed -------------------------
# Top level is brace depth, so a file whose delimiters do not balance was read
# at the wrong depth from the drift onward and may have under-reported. Silence
# there is indistinguishable from a clean file.
mkdir -p "$tmp/lib15/pkg"
printf 'fn broken() -> Int {\n  1\n' > "$tmp/lib15/pkg/x.vibe"
run_gate "$tmp/lib15" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 15: an unbalanced file was scanned silently"
elif ! printf '%s\n' "$out" | grep -q 'did not return to zero'; then
  bad "case 15: rejected, but not for the drift reason:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 15 ok: depth drift stops the gate"
fi

# The balanced control, so the case discriminates.
printf 'fn fine() -> Int {\n  1\n}\n' > "$tmp/lib15/pkg/x.vibe"
run_gate "$tmp/lib15" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 15 control: a balanced file should pass, got exit $rc"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 15 control ok: a balanced file passes"
fi

# --- Case 16: an interpolation may contain blocks ---------------------------
# A block\x27s braces inside `\{ ... }` are indistinguishable from the
# interpolation\x27s own closer unless they are counted, so ending at the first
# `}` reads the rest of the string as top-level code.
mkdir -p "$tmp/lib16/pkg"
cat > "$tmp/lib16/pkg/braced.vibe" <<'VEOF'
let s = "x \{if true { "ok" } else { "fn String::split" }} y"
VEOF
run_gate "$tmp/lib16" "$tmp/empty_allow.txt"
if [ "$rc" -ne 0 ]; then
  bad "case 16a: text inside a braced interpolation was reported as a declaration"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 16a ok: blocks inside an interpolation stay inside it"
fi

cat > "$tmp/lib16/pkg/braced.vibe" <<'VEOF'
let s = "x \{if true { "ok" } else { "no" }} y" fn String::index_of(a: String, b: String) -> Int {
  -1
}
VEOF
if ! grep -q "fn String::index_of" "$tmp/lib16/pkg/braced.vibe"; then
  bad "case 16b: the fixture does not contain the declaration it is testing"
fi
run_gate "$tmp/lib16" "$tmp/empty_allow.txt"
if [ "$rc" -eq 0 ]; then
  bad "case 16b: a shadow after a braced interpolation was NOT caught"
elif ! printf '%s\n' "$out" | grep -q 'String::index_of'; then
  bad "case 16b: the finding does not name String::index_of:"
  echo "$out" | sed 's/^/    /' >&2
else
  note "case 16b ok: a declaration after a braced interpolation is caught"
fi

if [ "$fail" -ne 0 ]; then
  echo "[shadow-gate-test] $fail case(s) failed" >&2
  exit 1
fi
echo "[shadow-gate-test] all cases passed"

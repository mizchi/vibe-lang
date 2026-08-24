#!/usr/bin/env bash
# Red/green for check_gate_portability.sh. Every case asserts the FIXTURE
# landed before believing the verdict -- a Red test that mutates nothing passes
# for the wrong reason, which is how #2248 shipped a check that could not fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/check_gate_portability.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vibe_gate_portability_test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/scripts"

fail() { echo "gate-portability self-test: $1" >&2; exit 1; }
ok() { echo "  ok  $1"; }

run() { VIBE_GATE_PORTABILITY_ROOT="$TMP_ROOT" bash "$CHECK" >"$TMP_ROOT/out" 2>&1; }

reset_tree() {
  rm -f "$TMP_ROOT"/scripts/*.sh
  cat > "$TMP_ROOT/scripts/clean.sh" <<'EOF'
#!/usr/bin/env bash
grep -qE '^ok$' "$1"
grep -qF 'literal' "$1"
awk -F'\t' '{print $2}' "$1" | grep -qx 'x'
grep -qE $'^row\tvalue$' "$1"
EOF
}

# --- green: a clean tree passes, and every construct a real gate needs is
# accepted. Without this the checker could pass by rejecting everything.
reset_tree
run || { cat "$TMP_ROOT/out" >&2; fail "a clean tree was rejected"; }
ok "a clean tree passes (grep -qE / -qF / awk -F'\\t' / \$'...\\t' all accepted)"

# --- red 1: ripgrep in command position.
reset_tree
printf '%s\n' 'rg -q pattern "$1"' >> "$TMP_ROOT/scripts/clean.sh"
grep -q "^rg -q pattern" "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "an rg call was accepted"; }
grep -qF 'uses `rg`' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out" >&2; fail "rg finding did not name the reason"; }
ok "an rg call is rejected"

# --- red 2: ripgrep behind a pipe.
reset_tree
printf '%s\n' 'printf x | rg -v y' >> "$TMP_ROOT/scripts/clean.sh"
grep -q "| rg -v y" "$TMP_ROOT/scripts/clean.sh" || fail "fixture 2 did not land"
run && fail "a piped rg call was accepted"
ok "a piped rg call is rejected"

# --- red 3: \t inside a plain single-quoted grep pattern.
reset_tree
printf '%s\n' "grep -qE '^row\\tvalue\$' \"\$1\"" >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'grep -qE ' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 3 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "an uninterpreted \\t was accepted"; }
grep -qF 'does not interpret' "$TMP_ROOT/out" || fail "\\t finding did not name the reason"
ok "\\t in a plain single-quoted grep pattern is rejected"

# --- red 4: \d, same trap.
reset_tree
printf '%s\n' "grep -qE '^v\\d+\$' \"\$1\"" >> "$TMP_ROOT/scripts/clean.sh"
run && fail "an uninterpreted \\d was accepted"
ok "\\d in a plain single-quoted grep pattern is rejected"

# --- red 4b: the same trap in DOUBLE quotes. Double quotes do not produce a
# tab either, and covering only one quote style would leave the identical
# defect one keystroke away (#2248 review).
reset_tree
printf '%s\n' 'grep -qE "^row\\tvalue$" "$1"' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'grep -qE "^row' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 4b did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "an uninterpreted \\t in double quotes was accepted"; }
ok "\\t in a double-quoted grep pattern is rejected"

# --- green guard for 4b: a double-quoted pattern with no such escape, and an
# awk -F'"'"'\t'"'"' on the same line, must both still pass. Without this the
# double-quote rule could be satisfied by rejecting every double-quoted grep.
reset_tree
printf '%s\n' 'grep -qE "^ok-[0-9]+$" "$1"' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a clean double-quoted grep pattern was rejected"; }
ok "a double-quoted grep pattern without \\t or \\d still passes"

# --- red 5: the checker must not exempt a file by finding the violation in a
# comment only. A commented-out rg call is not a call.
reset_tree
printf '%s\n' '# rg -q pattern "$1"   -- historical note' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a commented-out rg mention was rejected"; }
ok "a whole-line comment mentioning rg is not a finding"

# --- red 6: an empty scan must FAIL rather than report success. A checker
# whose corpus silently becomes empty is the shape that let five broken
# self-tests sit green (#2252).
if VIBE_GATE_PORTABILITY_ROOT="$TMP_ROOT/nowhere" bash "$CHECK" >"$TMP_ROOT/out" 2>&1; then
  fail "a missing scan directory was reported as clean"
fi
ok "a missing scan directory fails rather than passing vacuously"

echo "[gate-portability-test] ok"

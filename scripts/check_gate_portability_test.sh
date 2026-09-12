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

# --- red 1b: ripgrep through an ABSOLUTE PATH. `/` had to stay excluded on the
# right of the word boundary (`rg/` is a directory), and excluding it on the
# LEFT too let `/usr/bin/rg` through entirely -- the straightforward way to
# bring the dependency back with this audit green (#2248 review).
reset_tree
printf '%s\n' '/usr/bin/rg -q pattern "$1"' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF '/usr/bin/rg -q' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1b did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "an absolute-path rg call was accepted"; }
grep -qF 'uses `rg`' "$TMP_ROOT/out" || fail "abs-path rg finding did not name the reason"
ok "an rg call through an absolute path is rejected"

# --- green guard for 1b: a directory that merely ENDS in rg is not the tool.
reset_tree
printf '%s\n' 'grep -qE "^x$" rg/data.txt' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a path containing rg/ was rejected as the tool"; }
ok "a directory named rg/ is not mistaken for the tool"

# --- red 1c: `sed -i` with no suffix. GNU takes an optional one, BSD/macOS
# REQUIRES one, so the bare form aborts there. The instance was in
# check_book_console_test.sh, a release-check dependency.
reset_tree
printf '%s\n' 'sed -i "s/a/b/" "$1"' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'sed -i "s/a/b/"' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1c did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a bare sed -i was accepted"; }
grep -qF 'BSD/macOS requires one' "$TMP_ROOT/out" || fail "sed -i finding did not name the reason"
ok "a bare sed -i is rejected"

# --- green guard for 1c: both portable spellings must still pass, or the rule
# could be satisfied by rejecting every sed.
reset_tree
printf '%s\n' 'sed -i.bak "s/a/b/" "$1"' >> "$TMP_ROOT/scripts/clean.sh"
printf '%s\n' 'sed "s/a/b/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a portable sed spelling was rejected"; }
ok "sed -i.bak and a temp-file edit still pass"

# --- red 1d: `mapfile` (bash 4). macOS ships bash 3.2, so the script aborts
# before it validates anything -- a gate that cannot start. Eleven uses across
# six scripts, including both formatter entry points, had accumulated under
# this gate before it had a rule for them (#2349).
reset_tree
printf '%s\n' 'mapfile -t files < <(git ls-files)' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'mapfile -t files' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1d did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a mapfile call was accepted"; }
grep -qF 'bash 4 builtin' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out" >&2; fail "mapfile finding did not name the reason"; }
ok "a mapfile call is rejected"

# --- red 1e: the `readarray` synonym, and the NUL-delimited spelling.
reset_tree
printf '%s\n' 'readarray -t files < <(git ls-files)' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'readarray -t files' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1e did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a readarray call was accepted"; }
ok "the readarray synonym is rejected"

reset_tree
printf '%s\n' 'mapfile -d "" -t files < <(find . -print0)' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'mapfile -d' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1e2 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "a NUL-delimited mapfile call was accepted"; }
ok "the NUL-delimited mapfile spelling is rejected"

# --- red 1f: PREFIXED invocations. A command-position rule was the first
# draft, and `if mapfile ...`, `command mapfile ...`, `! mapfile ...` and
# `FOO=bar mapfile ...` all ran the builtin and all sailed past it (Codex on
# #2588). Each is asserted on its own so a rule that fixes one and misses
# another cannot pass.
for prefixed in \
  'if mapfile -t xs < input; then echo hi; fi' \
  'command mapfile -t ys < input' \
  '! mapfile -t zs < input' \
  'FOO=bar mapfile -t ws < input'; do
  reset_tree
  printf '%s\n' "$prefixed" >> "$TMP_ROOT/scripts/clean.sh"
  grep -qF "$prefixed" "$TMP_ROOT/scripts/clean.sh" || fail "fixture 1f did not land: $prefixed"
  run && { cat "$TMP_ROOT/out" >&2; fail "a prefixed mapfile call was accepted: $prefixed"; }
done
ok "prefixed mapfile calls (if / command / ! / VAR=) are rejected"

# --- green guard for 1d: the REPLACEMENT must pass, or the rule could be
# satisfied by rejecting every array fill; and a whole-line comment mentioning
# the builtin is not a call -- the six converted scripts each carry one.
reset_tree
cat >> "$TMP_ROOT/scripts/clean.sh" <<'EOF'
files=()
while IFS= read -r line || [ -n "$line" ]; do
  files+=("$line")
done < <(git ls-files)
# bash 3.2 has no mapfile, which is why this loop exists
EOF
run || { cat "$TMP_ROOT/out" >&2; fail "the portable read-loop replacement was rejected"; }
ok "the read-loop replacement passes, and mapfile in a whole-line comment is not a call"

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

# --- red 7: the diag-swallowing redirection `2>/dev/null >&2` (#2688). The
# redirections apply left to right, so `2>/dev/null` points stderr at
# /dev/null and `>&2` then dups stdout onto that -- the sidecar goes to
# /dev/null and only the caller's generic line shows.
reset_tree
printf '%s\n' 'cat "$out.diag" 2>/dev/null >&2 || true' >> "$TMP_ROOT/scripts/clean.sh"
grep -qF 'cat "$out.diag" 2>/dev/null >&2' "$TMP_ROOT/scripts/clean.sh" || fail "fixture 7 did not land"
run && { cat "$TMP_ROOT/out" >&2; fail "the 2>/dev/null >&2 diag-swallow was accepted"; }
grep -qF 'sends the message to /dev/null' "$TMP_ROOT/out" || { cat "$TMP_ROOT/out" >&2; fail "diag-swallow finding did not name the reason"; }
ok "the 2>/dev/null >&2 diag-swallowing redirection is rejected"

# --- green guard for 7: the corrected order must pass, or the rule could be
# satisfied by rejecting every redirection to stderr.
reset_tree
printf '%s\n' 'cat "$out.diag" >&2 2>/dev/null || true' >> "$TMP_ROOT/scripts/clean.sh"
printf '%s\n' 'foo >/dev/null 2>&1 || true' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "the corrected >&2 2>/dev/null form (or >/dev/null 2>&1) was rejected"; }
ok "the corrected >&2 2>/dev/null form and the discard-both >/dev/null 2>&1 both pass"

# --- red 7b: the checker must not flag the idiom in a whole-line comment. One
# such comment documents the historical bug in install_test.sh, and rewriting
# it to the correct order would make the sentence false.
reset_tree
printf '%s\n' '# cat "$x.diag" 2>/dev/null >&2 sent the message to /dev/null (historical, #2688)' >> "$TMP_ROOT/scripts/clean.sh"
run || { cat "$TMP_ROOT/out" >&2; fail "a comment documenting the 2>/dev/null >&2 bug was rejected"; }
ok "the 2>/dev/null >&2 idiom in a whole-line comment is not a finding"

echo "[gate-portability-test] ok"

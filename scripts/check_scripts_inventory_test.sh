#!/usr/bin/env bash
# Self-test for scripts/check_scripts_inventory.vibex (#3675, #2248).
#
# Every case mutates a synthetic tree and asserts the gate goes red with the
# message for that defect, with the unmutated tree as the control. Each
# mutation also asserts that it landed: an edit that matched nothing passes
# while proving nothing. The real tree must pass too, or nothing here says
# anything about this repository. The README cases are the ones
# check_scripts_readme_test.sh carried before this gate replaced it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_REL="_build/scripts_inventory_test.$$"
WORK="$ROOT_DIR/$WORK_REL"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { printf 'scripts-inventory-test: ok: %s\n' "$1"; }
fail() { printf 'scripts-inventory-test: FAIL: %s\n' "$1" >&2; fails=1; }
gate() { bash "$ROOT_DIR/scripts/vibe_run.sh" scripts/check_scripts_inventory.vibex -- "$@" > "$WORK/out" 2>&1; }

tree="$WORK/tree"
inv="$tree/scripts/inventory.tsv"
readme="$tree/scripts/README.md"
# A well-formed synthetic tree: a plain script and its self-test, a script in
# a subdirectory, a brace group, a .vibex, a data file, and a root-relative
# path; an inventory row for each file.
build_tree() {
  rm -rf "$tree"
  mkdir -p "$tree/scripts/pkfire" "$tree/install"
  for f in scripts/a.sh scripts/b_test.sh scripts/pkfire/shard.sh \
           scripts/d_x.sh scripts/d_y.sh install/install.sh; do
    printf '#!/usr/bin/env bash\n' > "$tree/$f"
  done
  printf 'fn main allows () {\n  ()\n}\n' > "$tree/scripts/tool.vibex"
  printf 'x\n' > "$tree/scripts/list.txt"
  cat > "$readme" <<'EOF'
# scripts/ -- index
Run with `pkf run` or `bash scripts/a.sh --check`.
- `a.sh` (+ `b_test.sh`) -- the plain case
- `shard.sh` lives in `scripts/pkfire/`
- `d_{x,y}.sh` -- a brace group
- `*_test.sh` -- a glob
- `install/install.sh` -- a root-relative path
EOF
  printf '%s\n' \
    '# path	category	entry	host	removal' \
    'README.md	doc	manual	-	-' \
    'a.sh	gate	install/install.sh	launches: node	-' \
    'b_test.sh	self-test	scripts/a.sh	launches: other scripts	-' \
    'd_x.sh	tool	manual	#3672	-' \
    'd_y.sh	tool	manual	#3672	-' \
    'inventory.tsv	data	manual	-	-' \
    'list.txt	data	glob:scripts/a.sh	-	-' \
    'pkfire/shard.sh	build	manual	launches: pkf	-' \
    'tool.vibex	tool	manual	-	-' > "$inv"
}
expect_red() { # <case> <expected substring>
  if gate --root "$WORK_REL/tree"; then
    cat "$WORK/out" >&2; fail "$1: expected a failure, got ok"; return
  fi
  if grep -qF -- "$2" "$WORK/out"; then pass "$1"; else cat "$WORK/out" >&2; fail "$1: failed, but not with \"$2\""; fi
}

# The real tree.
if gate && grep -q '^scripts-inventory: ok (' "$WORK/out"; then
  pass "real tree ($(sed -n 's/^scripts-inventory: ok (\(.*\))$/\1/p' "$WORK/out"))"
else
  cat "$WORK/out" >&2; fail "the real scripts/ must pass"
fi

# Control.
build_tree
if gate --root "$WORK_REL/tree" && grep -qF 'scripts-inventory: ok (9 files registered; 6 names and 1 patterns' "$WORK/out"; then
  pass "control: the synthetic tree passes (9 files, 6 names, 1 pattern)"
else
  cat "$WORK/out" >&2; fail "control: the synthetic tree must pass with 9 files, 6 names and 1 pattern"
fi

# --- the inventory -------------------------------------------------------------
build_tree; printf 'x\n' > "$tree/scripts/new.sh"
expect_red "an unregistered file" 'scripts/new.sh has no row in scripts/inventory.tsv'

build_tree; printf 'gone.sh\ttool\tmanual\t#3672\t-\n' >> "$inv"
expect_red "a row for a file that is not there" '`gone.sh` is not under scripts/'

build_tree; printf 'a.sh\tgate\tmanual\tlaunches: node\t-\n' >> "$inv"
expect_red "a duplicate row" '`a.sh` has a second row'

build_tree; sed 's/^d_x\.sh	tool/d_x.sh	helper/' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
grep -q 'd_x.sh	helper' "$inv" || fail "unknown category: the mutation did not land"
expect_red "an unknown category" 'has category `helper`'

build_tree; sed 's/^d_y\.sh	tool	manual	#3672	-$/d_y.sh	tool	manual	#3672/' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
grep -qx 'd_y.sh	tool	manual	#3672' "$inv" || fail "malformed row: the mutation did not land"
expect_red "a row with four fields" 'expected 5 tab-separated fields'

build_tree; sed 's|^a\.sh	gate	install/install\.sh|a.sh	gate	Taskfile.pkl|' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
grep -q 'a.sh	gate	Taskfile.pkl' "$inv" || fail "missing entry: the mutation did not land"
expect_red "an entry that is not there" 'names entry `Taskfile.pkl`, and `Taskfile.pkl` is not there'

build_tree; sed 's/^a\.sh	gate	install\/install\.sh	launches: node/a.sh	gate	install\/install.sh	-/' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
grep -q 'a.sh	gate	install/install.sh	-' "$inv" || fail "no host reason: the mutation did not land"
expect_red "a script with no host reason" '`a.sh` is a non-.vibex script with no host reason'

build_tree; sed 's/^d_x\.sh	tool	manual	#3672/d_x.sh	tool	manual	#todo/' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
grep -q 'd_x.sh	tool	manual	#todo' "$inv" || fail "bad issue: the mutation did not land"
expect_red "a host that is not an issue number" 'has host `#todo`'

build_tree; rm "$inv"
expect_red "no inventory" 'scripts/inventory.tsv is missing'

# --- scripts/README.md ---------------------------------------------------------
build_tree; rm "$tree/scripts/a.sh"; sed '/^a\.sh	/d' "$inv" > "$WORK/t" && mv "$WORK/t" "$inv"
expect_red "a named script that is gone" 'names `a.sh`, and nothing is there'

build_tree; printf -- '- `ghost.sh` -- never written\n' >> "$readme"
expect_red "a name for a script that never existed" 'names `ghost.sh`'

build_tree; printf -- '- `nomatch_*.sh`\n' >> "$readme"
expect_red "a pattern matching no file" 'the pattern `nomatch_*.sh` matches no file'

build_tree; sed 's/d_{x,y}\.sh/d_{x,z}.sh/' "$readme" > "$WORK/t" && mv "$WORK/t" "$readme"
grep -q 'd_{x,z}' "$readme" || fail "brace member: the mutation did not land"
expect_red "a brace member that is gone" 'names `d_z.sh` (from `d_{x,z}.sh`)'

build_tree; printf -- '- `e_{a,{b,c}}.sh`\n' >> "$readme"
expect_red "nested braces" 'has nested or unbalanced braces'

build_tree; printf '# scripts/\nNothing in backticks here.\n' > "$readme"
expect_red "a README with no names" 'no script name parsed out of it'

# --list prints what each name resolved to, and exits 0.
build_tree
want_list=$'shard.sh\tshard.sh\tscripts/pkfire/shard.sh'
if gate --root "$WORK_REL/tree" --list && grep -qF "$want_list" "$WORK/out"; then
  pass "--list resolves a subdirectory name"
else
  cat "$WORK/out" >&2; fail "--list must print shard.sh -> scripts/pkfire/shard.sh"
fi

[ "$fails" = 0 ] || exit 1
echo "scripts-inventory-test: ok"

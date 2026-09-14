#!/usr/bin/env bash
# check_scripts_readme_test.sh -- red test for check_scripts_readme.sh.
#
# Per AGENTS.md ("a passing gate means nothing until it is known to be able to
# fail"): every case MUTATES a synthetic tree and asserts the gate goes red with
# the message for that specific defect, with an unmutated tree as the control.
# Each mutation also asserts that it LANDED, since an edit that matched nothing
# passes while proving nothing (#2248).
#
# The tree is synthetic so the cases stay fixed while scripts/ changes; the
# gate's ability to fail on the REAL tree was established on the commit that
# introduced it, where it reported the four names that had drifted.
#
# #2252: the gate's own environment variable is unset at the top and set
# explicitly per case, never inherited from the surrounding shell.

set -euo pipefail

unset VIBE_SCRIPTS_README_ROOT

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo_root/scripts/check_scripts_readme.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_scripts_readme_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf 'scripts-readme-test: ok: %s\n' "$1"; }
fail() { printf 'scripts-readme-test: FAIL: %s\n' "$1" >&2; fails=1; }

tree="$work/tree"
readme="$tree/scripts/README.md"

# A well-formed synthetic tree: a plain script, a self-test, a script in a
# subdirectory, a brace group, a glob, and a root-relative path.
build_tree() {
  rm -rf "$tree"
  mkdir -p "$tree/scripts/pkfire" "$tree/install"
  for f in scripts/a.sh scripts/b_test.sh scripts/pkfire/shard.sh \
           scripts/d_x.sh scripts/d_y.sh install/install.sh; do
    printf '#!/usr/bin/env bash\n' > "$tree/$f"
  done
  cat > "$readme" <<'EOF'
# scripts/ -- index

Run with `pkf run` or `bash scripts/a.sh --check`.

- `a.sh` (+ `b_test.sh`) -- the plain case
- `shard.sh` lives in `scripts/pkfire/`
- `d_{x,y}.sh` -- a brace group
- `*_test.sh` -- a glob
- `install/install.sh` -- a root-relative path
EOF
}

# run_gate <case> <expected substring>: the gate must fail AND say why.
expect_red() {
  name="$1"; want="$2"
  if VIBE_SCRIPTS_README_ROOT="$tree" bash "$gate" >"$work/out" 2>&1; then
    cat "$work/out" >&2
    fail "$name: expected a failure, got ok"
    return
  fi
  if grep -qF -- "$want" "$work/out"; then
    pass "$name"
  else
    cat "$work/out" >&2
    fail "$name: failed, but not with \"$want\""
  fi
}

# The real tree must pass, or nothing below says anything about this repo.
if bash "$gate" >"$work/real.out" 2>&1 && grep -q '^scripts-readme: ok (' "$work/real.out"; then
  pass "real tree passes ($(sed -n 's/^scripts-readme: ok (\(.*\))$/\1/p' "$work/real.out"))"
else
  cat "$work/real.out" >&2
  fail "the real scripts/README.md must pass"
fi

# Control: the synthetic tree passes and counts what it read.
build_tree
if VIBE_SCRIPTS_README_ROOT="$tree" bash "$gate" >"$work/out" 2>&1 \
   && grep -qF 'scripts-readme: ok (6 names and 1 patterns' "$work/out"; then
  pass "control: synthetic tree passes with 6 names and 1 pattern"
else
  cat "$work/out" >&2
  fail "control: synthetic tree must pass with 6 names and 1 pattern"
fi

# 1. A named script is deleted.
build_tree
rm "$tree/scripts/a.sh"
[ ! -e "$tree/scripts/a.sh" ] || fail "case 1: mutation did not land"
expect_red "case 1: a named script that is gone" 'names `a.sh`, and nothing is there'

# 2. The README names a script that never existed.
build_tree
printf -- '- `ghost.sh` -- never written\n' >> "$readme"
grep -q 'ghost.sh' "$readme" || fail "case 2: mutation did not land"
expect_red "case 2: a name for a script that never existed" 'names `ghost.sh`'

# 3. A glob matches nothing.
build_tree
printf -- '- `nomatch_*.sh`\n' >> "$readme"
grep -q 'nomatch_' "$readme" || fail "case 3: mutation did not land"
expect_red "case 3: a pattern matching no file" 'the pattern `nomatch_*.sh` matches no file'

# 4. One member of a brace group is missing; the message names the MEMBER.
build_tree
sed 's/d_{x,y}\.sh/d_{x,z}.sh/' "$readme" > "$work/t" && mv "$work/t" "$readme"
grep -q 'd_{x,z}' "$readme" || fail "case 4: mutation did not land"
expect_red "case 4: a brace member that is gone" 'names `d_z.sh` (from `d_{x,z}.sh`)'

# 5. Nested braces are refused, not guessed at.
build_tree
printf -- '- `e_{a,{b,c}}.sh`\n' >> "$readme"
grep -q 'e_{a,{b,c}}' "$readme" || fail "case 5: mutation did not land"
expect_red "case 5: nested braces are refused" 'has nested or unbalanced braces'

# 6. A README that yields no name fails closed instead of passing vacuously.
build_tree
printf '# scripts/\n\nNothing named here.\n' > "$readme"
grep -q 'Nothing named here' "$readme" || fail "case 6: mutation did not land"
expect_red "case 6: a README with no names fails closed" 'parsed no script names'

# 7. A script that exists only in the subdirectory still resolves (control for
#    the resolution rule), and stops resolving once it is gone from there.
build_tree
rm "$tree/scripts/pkfire/shard.sh"
[ ! -e "$tree/scripts/pkfire/shard.sh" ] || fail "case 7: mutation did not land"
expect_red "case 7: a subdirectory script that is gone" 'names `shard.sh`'

# 8. The mutated file is gone but a same-named DIRECTORY is there: a directory
#    is not a script, so the name must still fail.
build_tree
rm "$tree/scripts/a.sh" && mkdir "$tree/scripts/a.sh"
[ -d "$tree/scripts/a.sh" ] || fail "case 8: mutation did not land"
expect_red "case 8: a directory does not satisfy a script name" 'names `a.sh`, and nothing is there'

if [ "$fails" -ne 0 ]; then
  echo "scripts-readme-test: FAIL" >&2
  exit 1
fi
echo "scripts-readme-test: ok (real tree + control + 8 red cases)"

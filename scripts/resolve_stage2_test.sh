#!/usr/bin/env bash
# Red test for scripts/resolve_stage2.sh (#2836 §1).
#
# The two resolvers answer the same question and must answer it DIFFERENTLY:
# `resolve_stage2` degrades to the newest generation on disk and then to the
# committed seed, saying so on stderr; `resolve_stage2_strict` takes HEAD's
# generation or nothing. The whole value of the strict one is the refusal, so
# each case below sets up a tree where it MUST refuse and fails if it answers.
#
# Every case runs in a throwaway git repository, because both resolvers key on
# `git rev-parse --short HEAD` -- a case that ran here would key on this
# repository's HEAD and could not arrange the mismatch it is testing.
#
# Portability (#2252): nothing inherited, no non-POSIX tools.
set -euo pipefail
unset VIBE_STAGE2_WASM
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
resolver="$ROOT_DIR/scripts/resolve_stage2.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/vibe_resolve_stage2_test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

fail() { echo "[resolve-stage2-test] FAIL: $*" >&2; failures=$((failures + 1)); }

# A fresh repository with one commit, so HEAD has a short sha to arrange
# generations around. Committer identity is set locally: a container without a
# global git identity would otherwise fail here for a reason unrelated to the
# property under test.
new_repo() { # <name> -> echoes the repo path
  local repo="$work/$1"
  mkdir -p "$repo"
  git -C "$repo" init --quiet
  git -C "$repo" config user.email vibe@example.invalid
  git -C "$repo" config user.name vibe
  : > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit --quiet -m init
  printf '%s\n' "$repo"
}

plant_generation() { # <repo> <sha> [bytes]
  local dir="$1/_build/selfhost/generations/seed_$2"
  mkdir -p "$dir"
  printf '%s' "${3-stage2}" > "$dir/stage2.wasm"
}

# Runs one resolver inside <repo> and reports "<rc>|<stdout>". stderr is kept
# for the message assertions; it is where every fallback announces itself.
run_resolver() { # <repo> <fn> [override]
  local repo="$1" fn="$2" override="${3-}" out rc
  set +e
  out="$(cd "$repo" && . "$resolver" && "$fn" probe "$override" 2>"$work/stderr")"
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

# 1. The #2836 tree: a generation exists, but for another commit. This is what
#    a reused workspace looks like, and the two resolvers must disagree on it.
repo="$(new_repo stale)"
plant_generation "$repo" deadbee
result="$(run_resolver "$repo" resolve_stage2_strict)"
case "$result" in
  0\|*) fail "strict answered on a stale-generation tree: ${result#0|}" ;;
  *) grep -q "no generation for HEAD" "$work/stderr" ||
       fail "strict refused a stale-generation tree without saying why" ;;
esac
result="$(run_resolver "$repo" resolve_stage2)"
case "$result" in
  0\|*seed_deadbee/stage2.wasm)
    grep -q "NOTE no generation for HEAD" "$work/stderr" ||
      fail "lenient took the stale generation without a NOTE" ;;
  *) fail "lenient did not fall back to the stale generation: $result" ;;
esac

# 2. The generation HEAD asks for. Without this the refusals above would be
#    satisfied by a resolver that never answers at all.
repo="$(new_repo head)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
plant_generation "$repo" deadbee
plant_generation "$repo" "$sha"
result="$(run_resolver "$repo" resolve_stage2_strict)"
case "$result" in
  0\|*seed_$sha/stage2.wasm) : ;;
  *) fail "strict did not take HEAD's own generation: $result" ;;
esac
[ ! -s "$work/stderr" ] || fail "strict narrated a clean resolution: $(cat "$work/stderr")"

# 3. An EMPTY stage2.wasm for HEAD -- an interrupted or orphaned build. The
#    directory exists and carries the right sha, so a check on the directory
#    name alone would accept it and hand the runner a zero-byte compiler.
repo="$(new_repo empty)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
plant_generation "$repo" deadbee
plant_generation "$repo" "$sha" ""
result="$(run_resolver "$repo" resolve_stage2_strict)"
case "$result" in
  0\|*) fail "strict accepted an empty stage2.wasm: ${result#0|}" ;;
  *) : ;;
esac

# 4. The override is the caller saying which compiler to measure, and it wins
#    over everything -- including a HEAD generation that also exists.
repo="$(new_repo override)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
plant_generation "$repo" "$sha"
: > "$work/explicit.wasm"
result="$(run_resolver "$repo" resolve_stage2_strict "$work/explicit.wasm")"
case "$result" in
  "0|$work/explicit.wasm") : ;;
  *) fail "strict ignored an explicit override: $result" ;;
esac
# 5. ... and an override that does not exist is a refusal, not a silent
#    fallback to the generation that does.
result="$(run_resolver "$repo" resolve_stage2_strict "$work/absent.wasm")"
case "$result" in
  0\|*) fail "strict fell back from a missing override: ${result#0|}" ;;
  *) grep -q "override does not exist" "$work/stderr" ||
       fail "strict refused a missing override without saying why" ;;
esac

# 6. Outside a git checkout there is no HEAD to key on. The lenient resolver
#    still has the seed to offer; the strict one has nothing, and must say so
#    rather than reach for the newest directory.
mkdir -p "$work/nogit"
plant_generation "$work/nogit" deadbee
result="$(run_resolver "$work/nogit" resolve_stage2_strict)"
case "$result" in
  0\|*) fail "strict answered outside a git checkout: ${result#0|}" ;;
  *) grep -q "not a git checkout" "$work/stderr" ||
       fail "strict refused a non-checkout without saying why" ;;
esac

# --- resolve_stage2_generation / _or_seed (#3866) ---------------------------
# The fallback scripts run when no compiler was named. They take a ROOT and
# answer with absolute paths, so the run below is made from elsewhere.
run_gen() { # <repo> <fn>
  local repo="$1" fn="$2" out rc
  set +e
  out="$(cd "$work" && . "$resolver" && "$fn" probe "$repo" 2>"$work/stderr")"
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}
age() { # <repo> <generation> <touch -t stamp>
  touch -t "$3" "$1/_build/selfhost/generations/$2"
}

# 7. HEAD's generation wins over a NEWER one for another commit -- the case
#    `ls -t ... | head -1` answered wrong -- and needs no NOTE.
repo="$(new_repo gen_head)"
sha="$(git -C "$repo" rev-parse --short HEAD)"
plant_generation "$repo" "$sha"
plant_generation "$repo" deadbee
age "$repo" "seed_$sha" 202601010101
age "$repo" seed_deadbee 202601020101
result="$(run_gen "$repo" resolve_stage2_generation)"
case "$result" in
  "0|$repo/_build/selfhost/generations/seed_$sha/stage2.wasm") : ;;
  *) fail "generation did not take HEAD's own generation over a newer one: $result" ;;
esac
[ ! -s "$work/stderr" ] || fail "generation narrated a clean resolution: $(cat "$work/stderr")"

# 8. No generation for HEAD: the newest one that HAS a stage2.wasm, with a
#    NOTE. A newer directory whose stage2.wasm is empty (a build still running
#    or interrupted) is passed over.
repo="$(new_repo gen_newest)"
plant_generation "$repo" aaaaaaa
plant_generation "$repo" bbbbbbb
plant_generation "$repo" ccccccc ""
age "$repo" seed_aaaaaaa 202601010101
age "$repo" seed_bbbbbbb 202601020101
age "$repo" seed_ccccccc 202601030101
result="$(run_gen "$repo" resolve_stage2_generation)"
case "$result" in
  "0|$repo/_build/selfhost/generations/seed_bbbbbbb/stage2.wasm")
    grep -q "NOTE no generation for HEAD" "$work/stderr" ||
      fail "generation took a stale generation without a NOTE" ;;
  *) fail "generation did not take the newest complete generation: $result" ;;
esac

# 9. No generation at all: status 1 and silence, so the caller's own message
#    is the one shown. The seed is NOT offered, even when it is there.
repo="$(new_repo gen_none)"
mkdir -p "$repo/bootstrap/seed"
printf 'seed' > "$repo/bootstrap/seed/compiler.wasm"
result="$(run_gen "$repo" resolve_stage2_generation)"
case "$result" in
  "1|") [ ! -s "$work/stderr" ] || fail "generation narrated an empty tree: $(cat "$work/stderr")" ;;
  *) fail "generation answered on a tree with no generation: $result" ;;
esac
# 10. ... and the _or_seed form offers that seed, saying so.
result="$(run_gen "$repo" resolve_stage2_generation_or_seed)"
case "$result" in
  "0|$repo/bootstrap/seed/compiler.wasm")
    grep -q "falling back to the committed SEED" "$work/stderr" ||
      fail "or_seed took the seed without a NOTE" ;;
  *) fail "or_seed did not fall back to the seed: $result" ;;
esac
# 11. With no seed either, _or_seed has nothing to offer.
repo="$(new_repo gen_nothing)"
result="$(run_gen "$repo" resolve_stage2_generation_or_seed)"
case "$result" in
  1\|*) : ;;
  *) fail "or_seed answered with nothing to answer: $result" ;;
esac

if [ "$failures" -ne 0 ]; then
  echo "[resolve-stage2-test] FAIL: $failures case(s)" >&2
  exit 1
fi
echo "[resolve-stage2-test] ok"

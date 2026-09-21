#!/usr/bin/env bash
# Red/green for scripts/build_release_body.sh (#2248: a guard means nothing
# until it is shown to fail, and nothing good until it is shown NOT to fail on
# the inputs it must let through).
#
# This one guards a PERMANENT artifact: this repository publishes immutable
# releases, so a body that goes out with a dead link stays that way. Every red
# case below is a link that would have been published broken.
#
# Runs the real script against a scratch PROJECT_ROOT so the cases stay fixed
# while the actual release notes change.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-release-body-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The script falls back to `git remote` when this is unset; pin it so the test
# does not depend on the checkout's remote (#2252: a gate must not assume its
# environment).
export GITHUB_REPOSITORY="acme/demo"

fail=0
note() { printf '%s\n' "$*"; }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then note "  ok   $1"
  else note "  FAIL $1: got '$2' want '$3'"; fail=1; fi
}
contains() {
  if grep -qF "$2" "$1"; then note "  ok   contains: $2"
  else note "  FAIL missing: $2"; sed 's/^/      /' "$1"; fail=1; fi
}
absent() {
  if grep -qF "$2" "$1"; then note "  FAIL unexpectedly contains: $2"; sed 's/^/      /' "$1"; fail=1
  else note "  ok   free of: $2"; fi
}

tree() { # tree <dir> ; makes <dir>/scripts/<script> and the notes directory
  rm -rf "$1"
  mkdir -p "$1/scripts" "$1/docs/user/getting-started" "$1/docs/user/reference" "$1/docs/spec"
  cp "$ROOT_DIR/scripts/build_release_body.sh" "$1/scripts/"
  : > "$1/docs/user/reference/cheatsheet.md"
  : > "$1/docs/spec/0-1.md"
}

run() { # run <dir> <tag> <out> ; echoes the exit code, log in $WORK/log
  ( cd "$1" && bash scripts/build_release_body.sh "$2" "$3" ) > "$WORK/log" 2>&1
  echo $?
}

note "=== 1. green: relative links absolutized at the tag, others untouched ==="
tree "$WORK/g1"
cat > "$WORK/g1/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
# notes
See [the cheatsheet](../reference/cheatsheet.md) and [the spec](../../spec/0-1.md).
An issue: [#1](https://github.com/acme/demo/issues/1). An anchor: [here](#section).
MD
rc="$(run "$WORK/g1" v0.1.0 "$WORK/g1/out.md")"
check "exit" "$rc" "0"
contains "$WORK/g1/out.md" "](https://github.com/acme/demo/blob/v0.1.0/docs/user/reference/cheatsheet.md)"
contains "$WORK/g1/out.md" "](https://github.com/acme/demo/blob/v0.1.0/docs/spec/0-1.md)"
contains "$WORK/g1/out.md" "](https://github.com/acme/demo/issues/1)"
contains "$WORK/g1/out.md" "](#section)"
absent   "$WORK/g1/out.md" "../reference/cheatsheet.md"

note "=== 2. green: an anchor on a relative link survives the rewrite ==="
tree "$WORK/g2"
cat > "$WORK/g2/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
[section](../reference/cheatsheet.md#equality)
MD
rc="$(run "$WORK/g2" v0.1.0 "$WORK/g2/out.md")"
check "exit" "$rc" "0"
contains "$WORK/g2/out.md" "blob/v0.1.0/docs/user/reference/cheatsheet.md#equality)"

note "=== 3. green: a pre-release tag reads the base version's notes ==="
tree "$WORK/g3"
cat > "$WORK/g3/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
[c](../reference/cheatsheet.md)
MD
rc="$(run "$WORK/g3" v0.1.0-rc1 "$WORK/g3/out.md")"
check "exit" "$rc" "0"
contains "$WORK/g3/out.md" "blob/v0.1.0-rc1/docs/user/reference/cheatsheet.md"

note "=== 3b. green: a pre-release says so, and a release does NOT ==="
# The pre-release reads the RELEASE's notes, so without a banner the
# candidate's page is word for word the release announcement. The GitHub
# pre-release badge sits next to the title; the body is what a link lands on.
tree "$WORK/g4"
cat > "$WORK/g4/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
# vibe 0.1.0
[c](../reference/cheatsheet.md)
MD
rc="$(run "$WORK/g4" v0.1.0-rc.0 "$WORK/g4/rc.md")"
check "exit" "$rc" "0"
contains "$WORK/g4/rc.md" "release candidate (rc.0), not 0.1.0"
# The banner must lead: a reader who stops after the first line still knows.
check "banner is first" "$(head -1 "$WORK/g4/rc.md" | cut -c1-2)" "> "
rc="$(run "$WORK/g4" v0.1.0 "$WORK/g4/rel.md")"
check "exit" "$rc" "0"
absent   "$WORK/g4/rel.md" "release candidate"
check "release starts with the notes" "$(head -1 "$WORK/g4/rel.md")" "# vibe 0.1.0"
# Build metadata is not a pre-release: `1.0.0+build7` ships as the release.
rc="$(run "$WORK/g4" v0.1.0+build7 "$WORK/g4/meta.md")"
check "exit" "$rc" "0"
absent   "$WORK/g4/meta.md" "release candidate"

note "=== 4. red: no notes file for the version ==="
tree "$WORK/r1"
rc="$(run "$WORK/r1" v9.9.9 "$WORK/r1/out.md")"
check "exit" "$rc" "1"
contains "$WORK/log" "release-notes-9.9.9.md"
check "no body written" "$([ -e "$WORK/r1/out.md" ] && echo yes || echo no)" "no"

note "=== 5. red: a relative link that does not resolve ==="
tree "$WORK/r2"
cat > "$WORK/r2/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
[gone](../reference/deleted.md)
MD
rc="$(run "$WORK/r2" v0.1.0 "$WORK/r2/out.md")"
check "exit" "$rc" "1"
contains "$WORK/log" "../reference/deleted.md"
contains "$WORK/log" "does not exist"
check "no body written" "$([ -e "$WORK/r2/out.md" ] && echo yes || echo no)" "no"

note "=== 6. red: a relative link escaping the repository root ==="
tree "$WORK/r3"
cat > "$WORK/r3/docs/user/getting-started/release-notes-0.1.0.md" <<'MD'
[out](../../../../etc/passwd)
MD
rc="$(run "$WORK/r3" v0.1.0 "$WORK/r3/out.md")"
check "exit" "$rc" "1"
contains "$WORK/log" "escapes the repository root"
check "no body written" "$([ -e "$WORK/r3/out.md" ] && echo yes || echo no)" "no"

note "=== 7. red: a tag that is not a v-tag ==="
tree "$WORK/r4"
rc="$(run "$WORK/r4" seed/whatever "$WORK/r4/out.md")"
check "exit" "$rc" "1"
contains "$WORK/log" "must start with 'v'"

note
if [ "$fail" = 0 ]; then note "[build-release-body-test] ok"; else note "[build-release-body-test] FAIL"; fi
exit "$fail"

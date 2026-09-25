#!/usr/bin/env bash
# Red/green for scripts/build_release_assets.sh's TAG VALIDATION (#2248: a
# guard means nothing until it is shown to fail, and nothing good until it is
# shown not to fail on what it must let through).
#
# Only the argument-handling arms are exercised, deliberately: the asset build
# itself takes ~4 minutes and needs a compiler, while the defect this pins cost
# nothing to hit and could only surface at the tag --
#
#   $ bash scripts/build_release_assets.sh v0.1.0-rc.0
#   release-assets: invalid semver: 0.1.0-rc.0
#
# The grammar was `^[0-9]+\.[0-9]+\.[0-9]+$`, so EVERY pre-release tag died on
# release.yml's first job. `scripts/check_version_ladder.sh` had accepted the
# same spelling all along, so the tree held two different definitions of "a
# version" and nothing read them against each other.
#
# The version-agreement arm is checked against a scratch launcher rather than
# the real one, so these cases keep saying the same thing after the tree's own
# version moves on.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run_bounded.sh" # portable timeout(1), #2958

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vibe-release-assets-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail=0
note() { printf '%s\n' "$*"; }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then note "  ok   $1"
  else note "  FAIL $1: got '$2' want '$3'"; fail=1; fi
}
says() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  ok   says: $2"
  else note "  FAIL did not say: $2"; printf '%s\n' "$1" | sed 's/^/      /' | head -5; fail=1; fi
}
silent_about() {
  if printf '%s' "$1" | grep -qF "$2"; then note "  FAIL unexpectedly said: $2"; fail=1
  else note "  ok   free of: $2"; fi
}

# A scratch PROJECT_ROOT: the script resolves it from its own location, so the
# copy under $WORK/t/scripts reads $WORK/t/runtime/vibe.
setup() { # setup <launcher version>
  rm -rf "$WORK/t"
  mkdir -p "$WORK/t/scripts" "$WORK/t/runtime"
  cp "$ROOT_DIR/scripts/build_release_assets.sh" "$WORK/t/scripts/"
  printf 'set -euo pipefail\nVIBE_VERSION="%s"\n' "$1" > "$WORK/t/runtime/vibe"
}

run() { # run <tag> -> OUT, RC. Times out: past validation it would really build.
  OUT="$(run_bounded 25 bash "$WORK/t/scripts/build_release_assets.sh" "$1" 2>&1)"
  RC=$?
}

note "=== 1. green: a pre-release tag passes the grammar (the #2248 defect) ==="
setup "0.1.0-rc.0"; run v0.1.0-rc.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 2. green: the plain release tag still passes ==="
setup "0.1.0"; run v0.1.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 3. green: build metadata passes ==="
setup "0.1.0+build7"; run v0.1.0+build7
silent_about "$OUT" "invalid semver"

note "=== 4. green: the tag may be given without the leading v ==="
setup "0.1.0-rc.0"; run 0.1.0-rc.0
silent_about "$OUT" "invalid semver"
silent_about "$OUT" "VIBE_VERSION mismatch"

note "=== 5. red: a tag that is not a version at all ==="
setup "0.1.0"; run vnope
check "exit" "$RC" "1"
says "$OUT" "invalid semver: nope"

note "=== 6. red: a version-shaped tag with a junk pre-release ==="
# `+` is not a legal pre-release character; it opens build metadata, so
# `1.0.0-rc+` has an empty metadata field and must not be accepted.
setup "0.1.0"; run "v1.0.0-rc+"
check "exit" "$RC" "1"
says "$OUT" "invalid semver"

note "=== 7. red: the launcher and the tag disagree ==="
# The guard that stops a release shipping a version it does not report. An rc
# tree must not be publishable under the release's own number.
setup "0.1.0-rc.0"; run v0.1.0
check "exit" "$RC" "1"
says "$OUT" "VIBE_VERSION mismatch"
says "$OUT" "got=0.1.0-rc.0"

note "=== 8. red: and the reverse -- a release tree tagged as a candidate ==="
setup "0.1.0"; run v0.1.0-rc.0
check "exit" "$RC" "1"
says "$OUT" "VIBE_VERSION mismatch"

note
if [ "$fail" = 0 ]; then note "[build-release-assets-test] ok"; else note "[build-release-assets-test] FAIL"; fi
exit "$fail"

#!/usr/bin/env bash
# check_version_ladder.sh -- one version number, checked wherever it is written.
#
# Before ADR-0109 the tree stated four different things at once: `runtime/vibe`
# reported 0.3.0, `docs/spec/1.0-freeze.md` promised a 1.0 freeze behind a "read
# 1.0 as 0.3" substitution banner, the roadmap called GA 0.3.0, and the release
# notes were filed under 0.3.0 -- while the only tag ever published was v0.0.1.
# Nothing read those four against each other, so they drifted for two
# renumberings.
#
# This check is pure text: no compiler, no network. It answers one question --
# does every place that names the toolchain version name the SAME one?
#
#   1. runtime/vibe's VIBE_VERSION parses as SemVer.
#   2. docs/release-notes-<release>.md exists for it (pre-release stripped, so
#      0.1.0-dev is checked against the 0.1.0 notes).
#   3. Those notes are about that version -- their H1 says so.
#   4. The roadmap's "Version ladder" table has a row for it.
#   5. The stable-surface document names the same version as the one its freeze
#      takes effect at.
#
# Empty output plus exit 0 means clean, like the rest of the tree's checks.
#
#   LADDER_LAUNCHER   override runtime/vibe
#   LADDER_DOCS       override the docs/ directory
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LAUNCHER="${LADDER_LAUNCHER:-runtime/vibe}"
DOCS="${LADDER_DOCS:-docs}"

fail() { echo "check-version-ladder: $*" >&2; exit 1; }

[ -f "$LAUNCHER" ] || fail "no such launcher: $LAUNCHER"

# 1. VIBE_VERSION parses as SemVer.
version="$(sed -n 's/^VIBE_VERSION="\([^"]*\)".*$/\1/p' "$LAUNCHER" | head -1)"
[ -n "$version" ] || fail "$LAUNCHER has no VIBE_VERSION assignment"
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'; then
  fail "VIBE_VERSION is not SemVer: $version"
fi

# The release a pre-release is heading for. `0.1.0-dev` documents 0.1.0; it is
# not a separate release with notes of its own.
release="${version%%-*}"; release="${release%%+*}"

# 2. The release has notes.
notes="$DOCS/release-notes-$release.md"
if [ ! -f "$notes" ]; then
  echo "check-version-ladder: $LAUNCHER reports $version, but $notes does not exist." >&2
  echo "  A version nobody wrote notes for is a version nobody can ship. Write them, or correct VIBE_VERSION." >&2
  exit 1
fi

# 3. The notes are about that version.
if ! head -1 "$notes" | grep -qF "$release"; then
  fail "$notes exists but its title does not name $release -- $(head -1 "$notes")"
fi

# 4. The roadmap ladder has a row for it.
roadmap="$DOCS/release-roadmap.md"
[ -f "$roadmap" ] || fail "no such roadmap: $roadmap"
ladder="$(sed -n '/^## Version ladder/,/^## /p' "$roadmap")"
[ -n "$ladder" ] || fail "$roadmap has no '## Version ladder' section"
if ! printf '%s' "$ladder" | grep -qF "\`$release\`"; then
  echo "check-version-ladder: the ladder in $roadmap has no row for \`$release\`, which $LAUNCHER reports." >&2
  echo "  Add the row, or correct VIBE_VERSION -- a version the roadmap does not list is one nobody agreed to." >&2
  exit 1
fi

# 5. The stable surface takes effect at the same version.
surface="$DOCS/spec/stable-surface.md"
[ -f "$surface" ] || fail "no such document: $surface"
if ! grep -qF "takes effect at the \`$release\` tag" "$surface"; then
  echo "check-version-ladder: $surface does not say the freeze takes effect at the \`$release\` tag." >&2
  echo "  The freeze document and the launcher must name the same version; a mismatch is how the 'read 1.0 as 0.3' banner happened." >&2
  exit 1
fi

echo "check-version-ladder: ok ($version -> release $release; notes, ladder and stable surface agree)"

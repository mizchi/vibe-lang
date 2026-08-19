#!/usr/bin/env bash
# Self-test for check_version_ladder.sh.
#
# A consistency check that cannot fail is decoration. Writing this test for the
# freeze-surface gate found three ways that one passed while checking nothing,
# so every rule below is proved Red on a tree built to violate it, and the real
# tree is proved Green.
#
# Pure text -- no compiler, no network.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
CHECK="$ROOT_DIR/scripts/check_version_ladder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# Build a synthetic tree that passes, then let each case break one thing.
# $1 = VIBE_VERSION, $2 = notes basename version, $3 = ladder version,
# $4 = stable-surface version. Equal values -> a consistent tree.
build() {
  local ver="$1" notes_ver="$2" ladder_ver="$3" surface_ver="$4"
  rm -rf "$WORK/t"; mkdir -p "$WORK/t/docs/spec"
  printf '#!/usr/bin/env bash\nVIBE_VERSION="%s"\n' "$ver" > "$WORK/t/vibe"
  if [ -n "$notes_ver" ]; then
    printf '# vibe %s release notes\n\nbody\n' "$notes_ver" > "$WORK/t/docs/release-notes-$notes_ver.md"
  fi
  printf '# roadmap\n\n## Version ladder\n\n| version | meaning |\n| --- | --- |\n| `%s` | target |\n\n## Next\n' \
    "$ladder_ver" > "$WORK/t/docs/release-roadmap.md"
  printf '# stable surface\n\nThe freeze takes effect at the `%s` tag.\n' \
    "$surface_ver" > "$WORK/t/docs/spec/stable-surface.md"
}

# $1 = expected exit code, $2 = what the case proves, $3 = substring the message
# must contain (optional)
expect() {
  local want="$1" what="$2" needle="${3:-}"
  local out rc
  out="$(LADDER_LAUNCHER="$WORK/t/vibe" LADDER_DOCS="$WORK/t/docs" bash "$CHECK" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "version-ladder self-test: FAIL: $what -- exit $rc, wanted $want"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF "$needle"; then
    echo "version-ladder self-test: FAIL: $what -- message did not mention '$needle'"; echo "$out" | sed 's/^/    /'
    fails=$((fails + 1)); return
  fi
  echo "  ok: $what"
}

# 1. A consistent tree passes.
build 0.4.0 0.4.0 0.4.0 0.4.0
expect 0 "a tree that names one version everywhere passes"

# 2. A pre-release is checked against the release it heads for, not against
#    itself -- 0.4.0-dev must not demand release-notes-0.4.0-dev.md.
build 0.4.0-rc.1 0.4.0 0.4.0 0.4.0
expect 0 "a pre-release resolves to its release"

# 3. No VIBE_VERSION at all.
build 0.4.0 0.4.0 0.4.0 0.4.0
printf '#!/usr/bin/env bash\necho hi\n' > "$WORK/t/vibe"
expect 1 "a launcher with no VIBE_VERSION fails" "no VIBE_VERSION"

# 4. A version string that is not SemVer.
build "0.4" 0.4.0 0.4.0 0.4.0
expect 1 "a non-SemVer version fails" "not SemVer"

# 5. The version has no release notes.
build 0.9.0 "" 0.9.0 0.9.0
expect 1 "a version with no notes fails" "does not exist"

# 6. Notes exist under the right name but are about something else. Catching
#    this needs reading the file, not just stat-ing it.
build 0.4.0 0.4.0 0.4.0 0.4.0
printf '# vibe 0.7.0 release notes\n' > "$WORK/t/docs/release-notes-0.4.0.md"
expect 1 "notes whose title names another version fail" "does not name"

# 7. The roadmap ladder does not list the version.
build 0.4.0 0.4.0 0.5.0 0.4.0
expect 1 "a version missing from the ladder fails" "no row for"

# 8. The roadmap has no ladder section at all.
build 0.4.0 0.4.0 0.4.0 0.4.0
printf '# roadmap\n\nno ladder here\n' > "$WORK/t/docs/release-roadmap.md"
expect 1 "a roadmap with no ladder section fails" "Version ladder"

# 9. The freeze takes effect at a different version -- the exact drift that
#    produced the "read 1.0 as 0.3" banner.
build 0.4.0 0.4.0 0.4.0 1.0.0
expect 1 "a stable surface naming another version fails" "takes effect"

# 10. A launcher path that does not exist is an error, not a silent skip.
out="$(LADDER_LAUNCHER="$WORK/t/nope" LADDER_DOCS="$WORK/t/docs" bash "$CHECK" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "version-ladder self-test: FAIL: a missing launcher passed instead of failing"
  fails=$((fails + 1))
else
  echo "  ok: a missing launcher is an error, not a skip"
fi

# 11. The real tree passes.
if bash "$CHECK" >/dev/null 2>&1; then
  echo "  ok: the repository's own tree is consistent"
else
  echo "version-ladder self-test: FAIL: the repository's own tree does not pass"
  bash "$CHECK" 2>&1 | sed 's/^/    /'
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "version-ladder self-test: $fails case(s) failed" >&2
  exit 1
fi
echo "version-ladder self-test: all cases passed"

#!/usr/bin/env bash
# `release.yml` must stage the release as a DRAFT and then promote it.
#
# This repository has immutable releases enabled: assets can only be attached
# before a release is published. Publishing directly created the release and
# then lost every upload -- measured at v0.1.0-rc.0:
#
#   Cannot upload asset vibe-toolchain-v0.1.0-rc.0.tar.gz to an immutable
#   release. GitHub only allows asset uploads before a release is published
#
# leaving a PUBLISHED pre-release with ZERO downloadable assets, which the same
# immutability makes uncorrectable in place. The workflow already encoded this
# rule for the release BODY (build_release_body.sh refuses a dead link because
# "a body cannot be corrected after publishing here") -- the assets were the
# half nobody connected.
#
# WHAT THIS CHECKS, AND WHAT IT DOES NOT.
#
# The property that matters is "the published release carries its assets", and
# that is only decidable by cutting a real tag against a real immutable-release
# repository. This gate cannot do that. So it checks the LEXICAL structure that
# the fix consists of, and says so rather than implying more:
#
#   1. the publish step stages a draft (`draft: true`)
#   2. a later step promotes it (`gh release edit ... --draft=false`)
#   3. that promotion VERIFIES the end state instead of assuming it -- the
#      v0.1.0-rc.0 failure produced a release that existed, was correctly
#      marked pre-release, and was empty, so "the step ran" is not the property
#
# The end-to-end check lives in the workflow itself (the promote step compares
# the published asset count against what was staged) and fires at the next tag.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${RELEASE_WORKFLOW:-$ROOT_DIR/.github/workflows/release.yml}"
[ -f "$WF" ] || { echo "release-draft-promote: no workflow at $WF" >&2; exit 2; }

fail=0
note() { printf '%s\n' "$*"; }

if grep -qE '^ +draft: true' "$WF"; then
  note "  ok   the publish step stages a draft"
else
  note "  FAIL no 'draft: true' -- assets would upload to an already-published immutable release"
  fail=1
fi

if grep -qE 'gh release edit .*--draft=false' "$WF"; then
  note "  ok   a later step promotes the draft"
else
  note "  FAIL nothing promotes the draft -- the release would never publish"
  fail=1
fi

# The promotion must read the published state back. Asserting the comparison
# exists, not merely that `gh release view` is mentioned somewhere.
if grep -qE 'assets=\$want_assets' "$WF" && grep -qE 'prerelease=\$want_pre' "$WF"; then
  note "  ok   the promotion verifies draft/prerelease/asset-count after publishing"
else
  note "  FAIL the promotion does not check what it published -- an empty release would pass"
  fail=1
fi

note
if [ "$fail" = 0 ]; then note "[release-draft-promote] ok"; else note "[release-draft-promote] FAIL"; fi
exit "$fail"

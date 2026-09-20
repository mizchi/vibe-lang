#!/usr/bin/env bash
# build_release_body.sh -- the GitHub release body for a `v*` tag, built from
# the release notes that ship in the repository.
#
# `.github/workflows/release.yml` used to publish with
# `generate_release_notes: true`, so the body was the list of pull requests
# merged since the previous release -- 72 of them for 0.1.0, against `v0.0.1`
# five months earlier. The repository already carries a written account of the
# release (`docs/user/getting-started/release-notes-<version>.md`), and 0.1.0
# is the first release usable by anyone but the author, so the page a newcomer
# lands on should be that account rather than a changelog dump.
#
# Naively passing the file as `body_path` does not work: it is written to be
# read inside `docs/`, so its links are relative (`../reference/cheatsheet.md`)
# and a release body resolves none of them. This script rewrites those to
# absolute blob URLs AT THE TAG, so the links a reader follows show the tree
# the release was cut from rather than whatever `main` says later.
#
# Everything here fails closed, because a release body cannot be corrected
# after the fact -- this repository publishes immutable releases:
#
#   - no notes file for the version              -> refuse, naming the path
#   - a relative link escaping the repository    -> refuse, naming the link
#   - a relative link to a file that is not there-> refuse, naming the link
#
# The alternative in each case is a published, permanent page with a dead link
# on it, which is the same defect class as a dangling doc citation
# (check_doc_path_citations.sh) with a worse blast radius.
#
# Absolute links (`https:`, `http:`, `mailto:`) and pure anchors (`#section`)
# are left exactly as written.
#
# Usage: build_release_body.sh <tag> <out-file>
#   <tag>        the full tag, e.g. `v0.1.0`
#   <out-file>   where to write the body
#
# GITHUB_REPOSITORY  owner/repo for the blob URLs. CI sets it; locally it is
#                    derived from `origin` when unset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

TAG="${1:-}"
OUT="${2:-}"
if [ -z "$TAG" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <tag> <out-file>" >&2
  exit 2
fi

case "$TAG" in
  v*) : ;;
  *) echo "build-release-body: tag must start with 'v' (got: $TAG)" >&2; exit 1 ;;
esac

VERSION="${TAG#v}"
# A pre-release documents the release it is heading for, the same reduction
# scripts/check_version_ladder.sh makes, so `0.1.0-rc1` reads the 0.1.0 notes.
# Build metadata goes first, because SemVer orders it last (`1.0.0-rc.1+b7`)
# and stripping only `-*` would leave `0.1.0+b7` looking for notes of its own.
# check_version_ladder.sh already reduced both; this one did not, so the two
# disagreed about which file a `+meta` tag reads -- found by the red/green
# case in scripts/build_release_body_test.sh, not at the tag.
BASE_VERSION="${VERSION%%+*}"
BASE_VERSION="${BASE_VERSION%%-*}"
NOTES_REL="docs/user/getting-started/release-notes-${BASE_VERSION}.md"

repo="${GITHUB_REPOSITORY:-}"
if [ -z "$repo" ]; then
  origin="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  # git@github.com:owner/repo.git and https://github.com/owner/repo(.git)
  repo="$(printf '%s' "$origin" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')"
fi
if [ -z "$repo" ]; then
  echo "build-release-body: cannot determine owner/repo; set GITHUB_REPOSITORY" >&2
  exit 1
fi

python3 - "$PROJECT_ROOT" "$NOTES_REL" "$TAG" "$repo" "$OUT" <<'PY'
import io, os, re, sys

root, notes_rel, tag, repo, out_path = sys.argv[1:6]
notes_abs = os.path.join(root, notes_rel)

if not os.path.isfile(notes_abs):
    print(f"build-release-body: no release notes for this tag: {notes_rel}", file=sys.stderr)
    print(f"build-release-body: write them, or publish under a tag whose notes exist", file=sys.stderr)
    sys.exit(1)

text = io.open(notes_abs, encoding="utf-8").read()
notes_dir = os.path.dirname(notes_rel)

# `[label](target)` and `![alt](target)`. Targets with spaces or parentheses
# are not rewritten -- markdown needs <> or escaping for those, and this
# repository has none; leaving them alone is better than half-parsing them.
LINK = re.compile(r"(!?\[[^\]]*\]\()([^)\s]+)(\))")
SKIP = ("http://", "https://", "mailto:", "#")

problems = []

def rewrite(m):
    prefix, target, suffix = m.group(1), m.group(2), m.group(3)
    if target.startswith(SKIP):
        return m.group(0)
    # Split a trailing anchor so `../x.md#s` resolves the file and keeps `#s`.
    path, _, anchor = target.partition("#")
    if not path:
        return m.group(0)
    resolved = os.path.normpath(os.path.join(notes_dir, path))
    if resolved.startswith(".."):
        problems.append(f"{target}: escapes the repository root")
        return m.group(0)
    if not os.path.exists(os.path.join(root, resolved)):
        problems.append(f"{target}: resolves to {resolved}, which does not exist")
        return m.group(0)
    url = f"https://github.com/{repo}/blob/{tag}/{resolved}"
    if anchor:
        url = f"{url}#{anchor}"
    return f"{prefix}{url}{suffix}"

body = LINK.sub(rewrite, text)

# A pre-release publishes the RELEASE's notes (0.1.0-rc.0 reads the 0.1.0
# ones), so without this the candidate's page reads word for word like the
# release announcement. The GitHub pre-release flag is not enough on its own:
# it is a badge next to the title, while the body is what someone lands on
# from a link, and the two must not disagree about what this is.
version = tag[1:] if tag.startswith("v") else tag
pre = version.partition("+")[0].partition("-")[2]
if pre:
    release = version.partition("-")[0]
    body = (
        f"> **This is a release candidate ({pre}), not {release}.**\n"
        f"> The notes below describe {release}. A candidate carries that content "
        f"under a number saying the bug hunt that promotes it is not finished, "
        f"so it is published as a pre-release and is not what the installer's "
        f"\"latest\" resolves to. Use it to find problems; use {release} to depend on.\n"
        "\n"
    ) + body

if problems:
    print("build-release-body: FAIL: the notes carry links that cannot be published:", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)
    print("", file=sys.stderr)
    print("  A release body is permanent here (immutable releases), so a dead link", file=sys.stderr)
    print("  cannot be corrected after publishing. Repoint each link and re-tag.", file=sys.stderr)
    sys.exit(1)

io.open(out_path, "w", encoding="utf-8").write(body)
rewritten = sum(1 for _ in LINK.finditer(text)) - sum(
    1 for m in LINK.finditer(text) if m.group(2).startswith(SKIP))
print(f"[build-release-body] {notes_rel} -> {out_path} ({rewritten} relative link(s) absolutized at {tag})", file=sys.stderr)
PY

#!/usr/bin/env bash
# check_doc_path_citations.sh -- a backticked file path in docs/ must resolve.
#
# A document that points at `lib/@vibe/compiler/loader/index.vibe` when the file
# is `loader/loader.vibe` costs a reader one failed lookup and a guess about
# whether the rest of the paragraph is stale too. The repository already treats
# that class as worth detecting rather than remembering (AGENTS.md, "review /
# bug-issue derived regression prevention"), and there were 145 such sites when
# this check was written.
#
# Scope: `docs/**/*.md`, excluding `docs/archive/` -- an archived document is a
# record of a moment, and rewriting its paths would falsify it.
#
# A citation passes if any of these hold:
#
#   1. It resolves, either from the repository root or under one of the prefixes
#      below. Compiler docs habitually write `checker/checker.vibe` for
#      `lib/@vibe/compiler/checker/checker.vibe`, and that is fine.
#   2. It is `src/**` or a `.mbt` / `.mbti` file. Those went with the retired
#      MoonBit host (#594); older rows cite them as the historical record of
#      where a decision landed, not as navigation.
#   3. Its line (or one within two lines) says the file is gone -- "現存しない", "no longer exists",
#      "removed", "retired", "deleted". Writing a path down precisely to say it
#      does not exist is legitimate and self-documenting; the rule is that you
#      have to say so.
#   4. It is listed in scripts/doc_path_citation_allowlist.txt. Every entry
#      there is debt: a real dangling citation nobody has resolved yet.
#
# Five of the compiler's files are build outputs rather than tracked sources
# (scripts/ensure_generated.sh), so a tree exported with `git checkout-index` --
# which is what the pre-commit hook lints -- does not contain them, and a
# citation to one would look dangling there. Set VIBE_DOC_CITATION_RESOLVE_ROOT
# to a real working tree to resolve against that as well as the current
# directory; the pre-commit hook points it at the repository root.
#
# Usage: bash scripts/check_doc_path_citations.sh [--list]
#   --list  print every unresolved citation including allowlisted ones, and
#           exit 0 -- use it to see what is left to fix.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

allowlist="scripts/doc_path_citation_allowlist.txt"
list_mode=0
[ "${1:-}" = "--list" ] && list_mode=1

python3 - "$allowlist" "$list_mode" "${VIBE_DOC_CITATION_RESOLVE_ROOT:-}" <<'PY'
import io, os, re, sys

allowlist_path, list_mode = sys.argv[1], sys.argv[2] == "1"
resolve_root = sys.argv[3] if len(sys.argv) > 3 else ""

allowed = set()
if os.path.exists(allowlist_path):
    for line in io.open(allowlist_path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if line:
            allowed.add(line)

# Where a doc-relative path may be rooted. Compiler docs write paths relative to
# the package they are describing.
PREFIXES = [
    "", "lib/@vibe/compiler/", "lib/@vibe/", "lib/@vibex/", "lib/",
    "formal/VibeFormal/", "formal/", "scripts/", "docs/",
]

# Only extensions that name a file in this repository. Bare words with dots
# (module.member, a.b) are not paths, so a path must contain a slash.
EXT = r"vibe|vibex|vpkg|mbt|mbti|sh|mjs|js|cjs|py|pkl|json|lean|toml|tsv|txt|wat|wit|md"
CITE = re.compile(r"`([A-Za-z_][\w./@*+-]*/[\w./@*+-]+\.(?:" + EXT + r"))`")

GONE = re.compile(
    r"現存しない|存在しない|no longer (exists|present)|"
    r"\bremoved\b|\bretired\b|\bdeleted\b|削除",
    re.IGNORECASE,
)

def resolves(target):
    roots = ["", resolve_root] if resolve_root else [""]
    return any(
        os.path.exists(os.path.join(root, prefix + target))
        for root in roots
        for prefix in PREFIXES
    )

findings = []
for root, dirs, files in os.walk("docs"):
    dirs[:] = [d for d in dirs if d != "archive"]
    for name in sorted(files):
        if not name.endswith(".md"):
            continue
        path = os.path.join(root, name)
        lines = io.open(path, encoding="utf-8").read().split("\n")
        for lineno, line in enumerate(lines, 1):
            # Prose wraps, so "... was removed" often lands on the next line.
            window = "\n".join(lines[max(0, lineno - 3):lineno + 2])
            for match in CITE.finditer(line):
                target = match.group(1)
                # A glob stands for a set, not a file.
                if "*" in target:
                    continue
                # Build outputs are not tracked; a doc may name one it produced.
                if target.startswith("_build/") or target.startswith("dist/"):
                    continue
                if resolves(target):
                    continue
                # Retired MoonBit host: historical record, not navigation.
                if target.startswith("src/") or target.endswith((".mbt", ".mbti")):
                    continue
                if GONE.search(window):
                    continue
                findings.append((path, lineno, target, target in allowed))

unresolved = [f for f in findings if not f[3]]

if list_mode:
    for path, lineno, target, was_allowed in findings:
        print(f"{path}:{lineno}: {target}{'  (allowlisted)' if was_allowed else ''}")
    print(
        f"check-doc-path-citations: {len(findings)} unresolved citation(s), "
        f"{len(findings) - len(unresolved)} allowlisted"
    )
    sys.exit(0)

if unresolved:
    for path, lineno, target, _ in unresolved:
        print(f"{path}:{lineno}: cites `{target}`, which does not exist", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "check-doc-path-citations: FAIL: "
        f"{len(unresolved)} citation(s) point at files that are not there.",
        file=sys.stderr,
    )
    print("  Repoint each to the current file, or say in the same line that it is", file=sys.stderr)
    print("  gone (現存しない / 'no longer exists' / 'removed') if that is the point.", file=sys.stderr)
    print(f"  Adding it to {allowlist_path} records it as debt instead.", file=sys.stderr)
    sys.exit(1)

stale = sorted(allowed - {f[2] for f in findings})
if stale:
    for target in stale:
        print(f"{allowlist_path}: `{target}` is allowlisted but no longer cited anywhere", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "check-doc-path-citations: FAIL: the allowlist has entries that are no longer "
        "needed. Delete them -- an allowlist that only grows stops being a ratchet.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"check-doc-path-citations: ok ({len(allowed)} allowlisted, 0 new)")
PY

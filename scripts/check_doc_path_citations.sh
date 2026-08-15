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
#   4. The pair (document, path) is listed in
#      scripts/doc_path_citation_allowlist.txt. Every entry there is debt: a real
#      dangling citation nobody has resolved yet. The key is the PAIR, so
#      allowlisting a bad path in one document does not license the same path in
#      another -- otherwise the number of bad sites could grow without the
#      allowlist changing, and it would not be a ratchet at all.
#
# Five compiler files are build outputs rather than tracked sources
# (scripts/ensure_generated.sh), so a `git checkout-index` export -- which is
# what the pre-commit hook lints -- does not contain them. They are exempt BY
# NAME rather than by resolving against the working tree: a general working-tree
# fallback would also find a file that a partial-stage commit deleted or renamed
# in the index but left lying around unstaged, which is exactly the staged-
# snapshot guarantee the hook exists to provide.
#
# VIBE_DOC_CITATION_DOCS_ROOT points the scan at a different tree (the hook sets
# it to the staged snapshot). Resolution still happens against the real
# repository, so a doc and the file it cites must move together.
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

python3 - "$allowlist" "$list_mode" "${VIBE_DOC_CITATION_DOCS_ROOT:-.}" "$repo_root" <<'PY'
import io, os, re, sys

allowlist_path, list_mode = sys.argv[1], sys.argv[2] == "1"
docs_root, repo_root = sys.argv[3], sys.argv[4]

# Entries are "<document> <path>" pairs.
allowed = set()
if os.path.exists(allowlist_path):
    for line in io.open(allowlist_path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 2:
            print(
                f"{allowlist_path}: expected '<document> <path>', got: {line}",
                file=sys.stderr,
            )
            sys.exit(2)
        allowed.add((parts[0], parts[1]))

# Where a doc-relative path may be rooted. Compiler docs write paths relative to
# the package they are describing.
PREFIXES = [
    "", "lib/@vibe/compiler/", "lib/@vibe/", "lib/@vibex/", "lib/",
    "formal/VibeFormal/", "formal/", "scripts/", "docs/",
]

# Only extensions that name a file in this repository. Bare words with dots
# (module.member, a.b) are not paths, so a path must contain a slash.
EXT = r"vibe|vibex|vpkg|mbt|mbti|sh|mjs|js|cjs|py|pkl|json|lean|toml|tsv|txt|wat|wit|md"
# Three shapes count as a citation:
# A citation is a rooted path with a directory component: `a/b.vibe`. A bare
# dotted word with no known extension (`Array.map`, `record.field`) is not a
# path, which is what the extension list buys.
#
# Two other shapes are deliberately NOT checked, because in these documents they
# are the language being documented rather than references into the tree, and
# the two uses are indistinguishable from the text:
#
#   Bare filenames. The compiler docs write "`checker.vibe` does X" about a file
#   three directories down, and the language docs write `index.vibe` about a
#   spelling the loader accepts -- there is not one `index.vibe` in this
#   repository and every mention of it is correct. Measured: requiring bare names
#   to resolve produced 22 false positives on that one word.
#
#   `./` and `../` paths. Every one in docs/ is an import-syntax example --
#   `PathRef`: `./foo.vibe`, `../foo.vibe`; directory-import resolution
#   `./dir` -> `./dir/index.vibe`; a root-escape failure on `../module/path.vibe`.
#   Measured: checking them found 5 such examples and 0 real citations.
CITE = re.compile(r"`([A-Za-z_][\w./@*+-]*/[\w./@*+-]+\.(?:" + EXT + r"))`")

# Build outputs of scripts/ensure_generated.sh: real files in a working tree,
# absent from a `git checkout-index` export. Exempt by name, not by falling back
# to the working tree -- see the header.
GENERATED = {
    "lib/@vibe/compiler/compiler_sources_bundle.vibe",
    "lib/@vibe/compiler/cli_adapter_bundle.vibe",
    "lib/@vibe/compiler/selfbuild_runtime_entry_bundle.vibe",
    "lib/@vibe/compiler/_cli_adapter_module_source.vibe",
    "lib/@vibe/compiler/cache/codegen_fingerprint.vibe",
}

GONE = re.compile(
    r"現存しない|存在しない|no longer (exists|present)|"
    r"\bremoved\b|\bretired\b|\bdeleted\b|削除",
    re.IGNORECASE,
)

def resolves(target, doc_dir):
    # Prefix-expand before checking both, so the doc-relative spelling of a
    # generated artifact (`cache/codegen_fingerprint.vibe`) is exempt too. It
    # resolves on a developer's machine, where the artifact has been built, and
    # not on a fresh CI checkout -- which is how this was found.
    for prefix in PREFIXES:
        candidate = prefix + target
        if candidate in GENERATED or os.path.exists(os.path.join(repo_root, candidate)):
            return True
    return False

findings = []
scanned = set()
for root, dirs, files in os.walk(os.path.join(docs_root, "docs")):
    dirs[:] = [d for d in dirs if d != "archive"]
    for name in sorted(files):
        if not name.endswith(".md"):
            continue
        path = os.path.relpath(os.path.join(root, name), docs_root)
        doc_dir = os.path.join(repo_root, os.path.dirname(path))
        scanned.add(path)
        lines = io.open(os.path.join(docs_root, path), encoding="utf-8").read().split("\n")
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
                if resolves(target, doc_dir):
                    continue
                # Retired MoonBit host: historical record, not navigation.
                if target.startswith("src/") or target.endswith((".mbt", ".mbti")):
                    continue
                if GONE.search(window):
                    continue
                findings.append((path, lineno, target, (path, target) in allowed))

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

# Only a document this run actually scanned can be judged. The pre-commit hook
# lints a staged snapshot, and precommit_test.sh runs against a synthetic repo
# with no docs/ at all -- neither is evidence that an entry is obsolete.
cited = {(f[0], f[2]) for f in findings}
stale = sorted(e for e in allowed if e[0] in scanned and e not in cited)
if stale:
    for doc, target in stale:
        print(f"{allowlist_path}: {doc} no longer cites `{target}`", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "check-doc-path-citations: FAIL: the allowlist has entries that are no longer "
        "needed. Delete them -- an allowlist that only grows stops being a ratchet.",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"check-doc-path-citations: ok ({len(allowed)} allowlisted, 0 new)")
PY

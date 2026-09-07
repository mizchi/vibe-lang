#!/usr/bin/env bash
# check_doc_classification.sh -- every document under docs/ has exactly one
# audience class, and a new one fails closed (#2562, part of #2002).
#
# docs/README.md is the audience router: four classes (user, maintainer /
# internal, generated, archive), one table row per document. It was written as
# an inventory and it has no enforcement, so the only thing standing between the
# classification and the tree is its own "Inventory coverage" section -- a list
# of names copied by hand from `ls docs/` at one commit.
#
# That is a PROXY for "every document is classified", not the property. It
# drifted within three weeks of being written: `checked-body-transport.md` and
# `source-range-contract.md` were in no class table at all,
# `archive/release-notes-0.3.0.md` was missing from the archive table, and
# docs/internal/ had been created with two files in it while the router stated
# ten lines from its top that `internal/` was "a label from #2002, not a
# directory in this commit". Nothing was checking, so nothing said so.
#
# This gate answers the property instead. It enumerates the tree and asks, for
# each file, which class claims it:
#
#   0 classes -> FAIL. Unclassified. The document exists and no reader knows
#                who it is for.
#   2 classes -> FAIL. Ambiguous ownership, which #2002's rule 4 forbids: a
#                normative statement has one canonical home.
#   a row matching nothing -> FAIL. A stale row is the same defect pointing the
#                other way, and it is what a move without a link rewrite leaves
#                behind.
#
# A row whose path is a DIRECTORY (`report/`, `wit/`, `archive/adr/`) covers
# every file beneath it. The router marks `guide/`, `spec/` and `wasm/` as mixed
# and classifies their children individually, so the scan descends rather than
# matching a prefix and stopping.
#
# A row pointing outside docs/ (`../book/README.md`) is skipped: the corpus is
# docs/, and book/ has its own gates (check_book_links.sh, vibe_md.sh,
# check_tutorial_translation_parity.sh).
#
# THE GATE MUST NOT BE ABLE TO SEE ITSELF (AGENTS.md, twice-learned in #2138).
# Two ways that could happen here, both closed:
#
#   1. docs/README.md is excluded from the corpus. It is the router -- it says
#      so of itself, "This file is the audience router. It is not one of the
#      four classes below." Scanning it would ask the router to classify
#      itself, which it can always do by existing.
#   2. The corpus comes from the filesystem, never from the router's own
#      "Inventory coverage" list. Reading that list would make the document the
#      evidence for a claim about the document -- the exact substitution this
#      gate exists to remove. Once this gate runs, that section is redundant by
#      construction.
#
# VIBE_DOC_CLASSIFICATION_ROOT points the scan at a different tree (the
# pre-commit hook's staged snapshot). The scan walks the filesystem rather than
# asking git, so it works in a `git checkout-index` export with no .git.
#
# Usage: bash scripts/check_doc_classification.sh [--list]
#   --list  print every file and the class that claims it, and exit 0.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

list_mode=0
[ "${1:-}" = "--list" ] && list_mode=1

python3 - "${VIBE_DOC_CLASSIFICATION_ROOT:-$repo_root}" "$list_mode" <<'PY'
import io, os, re, sys

tree_root, list_mode = sys.argv[1], sys.argv[2] == "1"
docs_dir = os.path.join(tree_root, "docs")
router_rel = "docs/README.md"
router_abs = os.path.join(tree_root, router_rel)

if not os.path.isdir(docs_dir):
    print(f"doc-classification: no docs/ under {tree_root}", file=sys.stderr)
    sys.exit(2)
if not os.path.exists(router_abs):
    print(f"doc-classification: {router_rel} is missing -- it is the router "
          "this gate reads the classification from", file=sys.stderr)
    sys.exit(2)

# --- the classification, read off the router's class tables -----------------
#
# A class is a `## <n>. <name>` heading. `###` sub-headings (Project,
# Operations, Design, Compiler, Reports) partition a class for reading and do
# not change it. Any other `## ` heading ends the class -- that is what keeps
# "## Inventory coverage" from being read as a fifth class.
#
# Only the FIRST column of a row is the classification. The Notes column also
# carries links (a directory row lists its children there), and counting those
# would report a file as classified twice for being mentioned.

CLASS_HEAD = re.compile(r"^## (\d)\. (.+?)\s*$")
ROW_PATH = re.compile(r"^\| \[[^\]]*\]\(([^)]+)\)")

cls = None
entries = []  # (class, docs-relative path, router line number)
for lineno, line in enumerate(
    io.open(router_abs, encoding="utf-8").read().split("\n"), start=1
):
    head = CLASS_HEAD.match(line)
    if head:
        cls = f"{head.group(1)}. {head.group(2)}"
        continue
    if line.startswith("## "):
        cls = None
        continue
    if cls is None or not line.startswith("| ["):
        continue
    row = ROW_PATH.match(line)
    if row:
        entries.append((cls, row.group(1), lineno))

if not entries:
    print(f"doc-classification: parsed no rows out of {router_rel}. The gate "
          "would pass by seeing nothing, so it fails instead -- check that the "
          "class headings still read `## 1. ...` and rows still start `| [`",
          file=sys.stderr)
    sys.exit(2)

# `../book/README.md` and friends leave docs/; book/ is covered by its own gates.
scoped = []
for cls, target, lineno in entries:
    if target.startswith("../"):
        continue
    scoped.append((cls, "docs/" + target.rstrip("/"), lineno))

# --- the corpus, read off the filesystem -------------------------------------

corpus = []
for root, dirs, files in os.walk(docs_dir):
    dirs[:] = sorted(d for d in dirs if d != ".git")
    for name in sorted(files):
        rel = os.path.relpath(os.path.join(root, name), tree_root)
        if rel == router_rel:
            continue  # the router is not one of its own four classes
        corpus.append(rel)
corpus.sort()

if not corpus:
    print("doc-classification: walked docs/ and found no files. The gate would "
          "pass by seeing nothing, so it fails instead", file=sys.stderr)
    sys.exit(2)


def claims(path):
    return sorted({c for c, t, _ in scoped if path == t or path.startswith(t + "/")})


fails = 0

if list_mode:
    for path in corpus:
        got = claims(path)
        print(f"{path}\t{got[0] if len(got) == 1 else ','.join(got) or '(none)'}")
    sys.exit(0)

unclassified = [p for p in corpus if not claims(p)]
ambiguous = [(p, claims(p)) for p in corpus if len(claims(p)) > 1]
stale = [
    (c, t, n)
    for c, t, n in scoped
    if not any(p == t or p.startswith(t + "/") for p in corpus)
]

for path in unclassified:
    print(
        f"doc-classification: FAIL: {path} is in no class table.\n"
        f"    Add a row for it to {router_rel} under the class whose PRIMARY "
        f"READER it is written for (#2002: classify by reader, not by the "
        f"subsystem it mentions).",
        file=sys.stderr,
    )
    fails += 1

for path, got in ambiguous:
    print(
        f"doc-classification: FAIL: {path} is claimed by {len(got)} classes "
        f"({', '.join(got)}).\n"
        f"    A normative statement has one canonical home (#2002 rule 4). "
        f"Delete the row in the class that is not its primary reader, or split "
        f"the document.",
        file=sys.stderr,
    )
    fails += 1

for cls, target, lineno in stale:
    print(
        f"doc-classification: FAIL: {router_rel}:{lineno} classifies "
        f"{target} under '{cls}', and nothing is there.\n"
        f"    Repoint the row at where the file moved, or delete the row if the "
        f"file is gone.",
        file=sys.stderr,
    )
    fails += 1

if fails:
    print(
        f"doc-classification: {fails} problem(s). "
        f"Run with --list to see what claims each file.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f"doc-classification: ok ({len(corpus)} documents, "
    f"{len(scoped)} rows, every document in exactly one class)"
)
PY

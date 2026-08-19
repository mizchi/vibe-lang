#!/usr/bin/env bash
# check_book_links.sh -- every relative link in The Vibe Book must resolve.
#
# The book is the onboarding surface: a reader who cannot get from chapter 1 to
# chapter 2 is finished with the language. When this was written, 28 of the
# book's 130 relative links were broken, including EVERY navigation link in the
# Japanese book -- `[02 制御フロー](02_control_flow-ja.vibe.md)` when the file
# is `book/ja/02_control_flow.vibe.md`. That is rename fallout from
# `docs/tutorial/NN_x-ja.vibe.md` -> `book/ja/NN_x.vibe.md`, and nothing read
# the links back, so the Japanese book had been unnavigable end to end.
#
# `check_doc_path_citations.sh` does not cover this: it checks BACKTICKED paths
# under `docs/`, and these are markdown link targets under `book/`.
#
# Fenced code blocks are skipped. `fn identity[T](x: T) -> T` matches the
# markdown link grammar and is not a link -- a checker that reports it teaches
# readers to ignore its output.
#
# Anchors are not verified, only the file part: an anchor that drifts is a
# smaller failure than a file that does not exist, and heading slugs differ
# between renderers.
#
# Empty output plus exit 0 means clean.
#
#   BOOK_DIR   override the directory to scan (default book)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

BOOK_DIR="${BOOK_DIR:-book}"
[ -d "$BOOK_DIR" ] || { echo "check-book-links: no such directory: $BOOK_DIR" >&2; exit 1; }

BOOK_DIR="$BOOK_DIR" python3 - <<'PYEOF'
import os, re, sys

root = os.environ["BOOK_DIR"]
LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

broken, total, files = [], 0, 0
for dirpath, _dirs, names in os.walk(root):
    for name in sorted(names):
        if not name.endswith(".md"):
            continue
        path = os.path.join(dirpath, name)
        files += 1
        fenced = False
        for lineno, line in enumerate(open(path, encoding="utf-8"), 1):
            # A fence toggles; ``` opens and the next ``` closes.
            if line.lstrip().startswith("```"):
                fenced = not fenced
                continue
            if fenced:
                continue
            for m in LINK.finditer(line):
                target = m.group(1)
                if target.startswith(("http://", "https://", "mailto:", "#")):
                    continue
                total += 1
                filepart = target.split("#", 1)[0]
                if not filepart:
                    continue
                if not os.path.exists(os.path.normpath(os.path.join(dirpath, filepart))):
                    broken.append((path, lineno, target))

if broken:
    for path, lineno, target in broken:
        print(f"{path}:{lineno}: broken link: {target}", file=sys.stderr)
    print(f"check-book-links: FAIL: {len(broken)} of {total} relative link(s) do not resolve.", file=sys.stderr)
    print("  A link target is a path relative to the file it appears in. Chapters live in", file=sys.stderr)
    print("  book/src/ and book/ja/; the index is ../README.md; repository docs are ../../docs/.", file=sys.stderr)
    sys.exit(1)

print(f"check-book-links: ok ({total} relative link(s) across {files} file(s) resolve)")
PYEOF

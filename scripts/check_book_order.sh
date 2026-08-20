#!/usr/bin/env bash
# The book has ONE reading order, and `book/SUMMARY.md` is it.
#
# It used to have three, which disagreed:
#
#   * SUMMARY.md          -- the rendered order, and a sane one
#   * the file numbering  -- a fossil of an earlier tour (`01_values_functions`
#                            … `19_a_small_program`)
#   * the `Next:` footers -- which followed the FILE numbers
#
# So a reader following the footer links left the SUMMARY spine at chapter 2
# and, walking only `Next:`, reached 12 of 20 chapters before hitting a dead
# end -- never seeing tests, modules, collections, generics or equality. One
# footer pointed back to chapter 3, making a cycle. `check_book_links.sh`
# could not see any of it: every one of those links RESOLVED. Resolving and
# being right are different questions.
#
# Checked, per chapter, against its position in SUMMARY.md:
#   1. the H1 is numbered with its SUMMARY position
#   2. `Previous:` names the SUMMARY predecessor (chapter 1 must have none)
#   3. `Next:` names the SUMMARY successor (the last chapter must have none)
#
# Not checked: prose link mentions inside a chapter body. Those are
# cross-references, not the spine, and a chapter may legitimately point
# forward to where a topic is finished.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 - <<'PY'
import re, sys

summary = open("book/SUMMARY.md", encoding="utf-8").read()

# The en/ chapter spine, in order. The ja/ list at the bottom is a translation
# index rather than a second spine, so it is matched by pairing, not by order.
spine = re.findall(r'^- \[([^\]]+)\]\((en/[0-9]{2}_[a-z_]+\.vibe\.md)\)', summary, re.M)
if len(spine) < 10:
    print(f"book-order: FAIL: read only {len(spine)} chapters out of SUMMARY.md -- the "
          f"list shape changed and this gate can no longer see its subject", file=sys.stderr)
    sys.exit(1)

fails = []
for i, (title, path) in enumerate(spine):
    n = i + 1
    body = open("book/" + path, encoding="utf-8").read()
    lines = body.split("\n")

    h1 = next((l for l in lines if l.startswith("# ")), "")
    m = re.match(r'#\s+(\d+)\s*[-—–]', h1)
    if not m:
        fails.append(f"{path}: the H1 must start with its chapter number "
                     f"(want `# {n:02d} — {title}`), got: {h1.strip() or '(no H1)'}")
    elif int(m.group(1)) != n:
        fails.append(f"{path}: H1 says chapter {m.group(1)}, but SUMMARY.md places it "
                     f"at {n}. SUMMARY is the order; renumber the heading.")

    prev_m = re.search(r'^Previous:\s*\[[^\]]*\]\(([0-9]{2}_[a-z_]+\.vibe\.md)\)', body, re.M)
    next_m = re.search(r'^Next:\s*\[[^\]]*\]\(([0-9]{2}_[a-z_]+\.vibe\.md)\)', body, re.M)

    want_prev = spine[i - 1][1].split("/")[-1] if i > 0 else None
    want_next = spine[i + 1][1].split("/")[-1] if i + 1 < len(spine) else None

    got_prev = prev_m.group(1) if prev_m else None
    got_next = next_m.group(1) if next_m else None

    if got_prev != want_prev:
        fails.append(f"{path}: Previous: is {got_prev or '(absent)'}, "
                     f"want {want_prev or '(absent -- this is the first chapter)'}")
    if got_next != want_next:
        fails.append(f"{path}: Next: is {got_next or '(absent)'}, "
                     f"want {want_next or '(absent -- this is the last chapter)'}")

for f in fails:
    print(f"book-order: FAIL: {f}", file=sys.stderr)
if fails:
    print(f"book-order: {len(fails)} chapter(s) disagree with book/SUMMARY.md", file=sys.stderr)
    sys.exit(1)
print(f"book-order: ok ({len(spine)} chapters follow book/SUMMARY.md, headings and "
      f"Previous/Next included)")
PY

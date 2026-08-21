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
#   3. `Next:` names the SUMMARY successor -- and at the two ends, the
#      intro and the appendix, which bracket the spine without being in it
#
# The SAME three checks run over book/ja/, paired by filename. The
# translation is not a second spine -- it follows the English one -- but it has
# its own copy of the heading and the footers, so it drifts on its own. It did:
# after the English side was repaired, ja/13 still called itself chapter 05 and
# pointed back to Option, and ja/14 through ja/20 carried NO footer at all, so
# the Japanese book simply stopped at chapter 13 (#2156 review). Japanese
# chapters spell the footers `前:` / `次:`.
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

def check_spine(prefix, prev_kw, next_kw, required):
    """Check one language's copy of the spine against SUMMARY's order.

    prefix   -- "en" or "ja"
    prev_kw  -- the footer keyword that names the previous chapter
    next_kw  -- ... the next one
    required -- fail when the file is missing (en), or skip it (ja: a chapter
                may legitimately have no translation yet -- that is
                check_tutorial_translation_parity.sh's question, not this one)
    """
    for i, (title, path) in enumerate(spine):
        name = path.split("/")[-1]
        fp = f"book/{prefix}/{name}"
        try:
            body = open(fp, encoding="utf-8").read()
        except OSError:
            if required:
                fails.append(f"{prefix}/{name}: listed in SUMMARY.md but not on disk")
            continue
        n = i + 1
        lines = body.split("\n")

        h1 = next((l for l in lines if l.startswith("# ")), "")
        m = re.match(r'#\s+(\d+)\s*[-—–]', h1)
        if not m:
            fails.append(f"{prefix}/{name}: the H1 must start with its chapter number "
                         f"(want `# {n:02d} — …`), got: {h1.strip() or '(no H1)'}")
        elif int(m.group(1)) != n:
            fails.append(f"{prefix}/{name}: H1 says chapter {m.group(1)}, but SUMMARY.md "
                         f"places it at {n}. SUMMARY is the order; renumber the heading.")

        pat = r'^(?:%s):\s*\[[^\]]*\]\((?:\.\./[a-z]+/)?([0-9]{2}_[a-z_]+\.(?:vibe\.)?md)\)'
        prev_m = re.search(pat % prev_kw, body, re.M)
        next_m = re.search(pat % next_kw, body, re.M)

        # The intro and the appendix bracket the spine without being in it
        # (SUMMARY lists them outside the chapter list), so the first chapter
        # links back to the intro and the last one forward to the appendix.
        want_prev = spine[i - 1][1].split("/")[-1] if i > 0 else "00_introduction.md"
        want_next = (spine[i + 1][1].split("/")[-1] if i + 1 < len(spine)
                     else "99_appendix.md")
        got_prev = prev_m.group(1) if prev_m else None
        got_next = next_m.group(1) if next_m else None

        if got_prev != want_prev:
            fails.append(f"{prefix}/{name}: {prev_kw}: is {got_prev or '(absent)'}, "
                         f"want {want_prev}")
        if got_next != want_next:
            fails.append(f"{prefix}/{name}: {next_kw}: is {got_next or '(absent)'}, "
                         f"want {want_next}")

check_spine("en", "Previous", "Next", required=True)
check_spine("ja", "前", "次", required=False)

for f in fails:
    print(f"book-order: FAIL: {f}", file=sys.stderr)
if fails:
    print(f"book-order: {len(fails)} chapter(s) disagree with book/SUMMARY.md", file=sys.stderr)
    sys.exit(1)
import os
ja_seen = sum(1 for _, path in spine if os.path.exists("book/ja/" + path.split("/")[-1]))
print(f"book-order: ok ({len(spine)} en chapters + {ja_seen} ja follow book/SUMMARY.md, "
      f"headings and prev/next included)")
PY

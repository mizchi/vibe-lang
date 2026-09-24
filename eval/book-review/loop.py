#!/usr/bin/env python3
"""Chapter loop and full-read loop for book-review.

A chapter loop measures one chapter (English and Japanese). A pass
aggregates chapter scores into a book score. The pass does not invent
a number for a chapter that has no current score.

  python3 eval/book-review/loop.py check [chapter_id]
  python3 eval/book-review/loop.py status
  python3 eval/book-review/loop.py blob <chapter_id>
  python3 eval/book-review/loop.py pass [--record]

BOOK_REVIEW_ROOT defaults to the repository root. BOOK_REVIEW_DATE
(YYYY-MM-DD) is used only by `pass --record`.
"""

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DIMS = [
    "prose_fidelity",
    "surface_agreement",
    "example_honesty",
    "learner_progression",
    "off_path_guidance",
]
# A full read is complete when these two are measured for every chapter.
# The other three need a compiler or a sequential re-read, and a missing
# one stays null instead of blocking the prose pass.
DOC_DIMS = ["prose_fidelity", "surface_agreement"]

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
CHAPTER_RE = re.compile(r"\(en/([^)/]+\.md)\)")


def repo_root():
    env = os.environ.get("BOOK_REVIEW_ROOT")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parents[2]


def chapter_id(en_name):
    stem = en_name[:-3] if en_name.endswith(".md") else en_name
    if stem.endswith(".vibe"):
        stem = stem[:-5]
    return stem


def chapters(root):
    summary = (root / "book" / "SUMMARY.md").read_text(encoding="utf-8")
    found = []
    seen = set()
    for name in CHAPTER_RE.findall(summary):
        cid = chapter_id(name)
        if cid in seen:
            continue
        seen.add(cid)
        found.append((cid, name))
    if not found:
        raise SystemExit("loop: no chapters in book/SUMMARY.md")
    return found


def pair(root, en_name):
    en = root / "book" / "en" / en_name
    ja = root / "book" / "ja" / en_name
    return en, ja


def blob(root, path):
    try:
        top = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        top = ""
    if top and Path(top).resolve() == root.resolve():
        out = subprocess.run(
            ["git", "-C", str(root), "hash-object", "--", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return out.stdout.strip()
    data = path.read_bytes()
    return "sha256:" + hashlib.sha256(data).hexdigest()


def fences(text):
    """Return (run, skip, plain, defects). defects are human lines."""
    lines = text.splitlines()
    run = skip = plain = 0
    defects = []
    i = 0
    while i < len(lines):
        line = lines[i]
        kind = None
        if line == "```vibe run":
            kind = "run"
            run += 1
        elif line == "```vibe skip":
            kind = "skip"
            skip += 1
        elif line == "```vibe":
            kind = "plain"
            plain += 1
        if kind is None:
            i += 1
            continue
        body_start = i + 1
        j = body_start
        while j < len(lines) and lines[j] != "```":
            j += 1
        if j >= len(lines):
            defects.append(f"unclosed ```vibe {kind} opening at line {i + 1}")
            break
        if kind == "skip":
            reason = ""
            for body_line in lines[body_start:j]:
                if body_line.strip() != "":
                    reason = body_line
                    break
            if not reason.startswith("// skip"):
                defects.append(
                    f"```vibe skip at line {i + 1} has no `// skip` reason"
                )
        if kind == "run":
            k = j + 1
            while k < len(lines) and lines[k].strip() == "":
                k += 1
            if k >= len(lines) or lines[k] != "```output":
                defects.append(
                    f"```vibe run at line {i + 1} is not followed by ```output"
                )
        i = j + 1
    return run, skip, plain, defects


def link_defects(path, text):
    defects = []
    for m in LINK_RE.finditer(text):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        if target.startswith("#"):
            continue
        path_part = target.split("#", 1)[0]
        if path_part == "":
            continue
        resolved = (path.parent / path_part).resolve()
        if not resolved.exists():
            line = text[: m.start()].count("\n") + 1
            defects.append(f"broken link at line {line}: {target}")
    return defects


def check_chapter(root, cid, en_name):
    en, ja = pair(root, en_name)
    defects = []
    if not en.is_file():
        defects.append(f"missing {en.relative_to(root)}")
    if not ja.is_file():
        defects.append(f"missing {ja.relative_to(root)}")
    if defects:
        return defects
    en_text = en.read_text(encoding="utf-8")
    ja_text = ja.read_text(encoding="utf-8")
    en_run, en_skip, en_plain, en_fence_def = fences(en_text)
    ja_run, ja_skip, ja_plain, ja_fence_def = fences(ja_text)
    for d in en_fence_def:
        defects.append(f"en: {d}")
    for d in ja_fence_def:
        defects.append(f"ja: {d}")
    if (en_run, en_skip, en_plain) != (ja_run, ja_skip, ja_plain):
        defects.append(
            "en/ja fence counts differ "
            f"(en run/skip/plain {en_run}/{en_skip}/{en_plain}, "
            f"ja {ja_run}/{ja_skip}/{ja_plain})"
        )
    for label, path, text in (("en", en, en_text), ("ja", ja, ja_text)):
        for d in link_defects(path, text):
            defects.append(f"{label}: {d}")
    return defects


def score_dir(root, cid):
    return root / "eval" / "book-review" / "scores" / "chapters" / cid


def latest_score(root, cid):
    directory = score_dir(root, cid)
    if not directory.is_dir():
        return None
    files = sorted(p for p in directory.glob("*.json") if p.is_file())
    if not files:
        return None
    return files[-1]


def load_score(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return None, f"invalid json ({exc})"
    if not isinstance(data, dict):
        return None, "score is not an object"
    dims = data.get("dimensions")
    if not isinstance(dims, dict) or set(dims) != set(DIMS):
        return None, f"dimensions must be exactly {DIMS}"
    for name in DIMS:
        row = dims[name]
        if not isinstance(row, dict):
            return None, f"{name} is not an object"
        measured = row.get("measured")
        score = row.get("score")
        if measured is True:
            if not isinstance(score, (int, float)) or isinstance(score, bool):
                return None, f"{name} measured but score is not a number"
            if score < 1 or score > 5:
                return None, f"{name} score {score} is outside 1-5"
        elif measured is False:
            if score is not None:
                return None, f"{name} is unmeasured but score is not null"
        else:
            return None, f"{name}.measured must be true or false"
    blobs = data.get("blobs")
    if not isinstance(blobs, dict) or "en" not in blobs or "ja" not in blobs:
        return None, "blobs.en and blobs.ja are required"
    if data.get("unit") != "chapter":
        return None, "unit must be \"chapter\""
    return data, None


def score_state(root, cid, en_name):
    path = latest_score(root, cid)
    if path is None:
        return "missing", None, None
    data, err = load_score(path)
    if err:
        return "invalid", path, err
    if data.get("chapter") != cid:
        return "invalid", path, f"chapter field is {data.get('chapter')}"
    en, ja = pair(root, en_name)
    if not en.is_file() or not ja.is_file():
        return "invalid", path, "chapter files missing"
    current = {"en": blob(root, en), "ja": blob(root, ja)}
    recorded = data["blobs"]
    if recorded.get("en") != current["en"] or recorded.get("ja") != current["ja"]:
        return "stale", path, data
    return "current", path, data


def doc_measured(data):
    dims = data["dimensions"]
    return all(dims[name]["measured"] is True for name in DOC_DIMS)


def cmd_check(root, only):
    failed = 0
    for cid, en_name in chapters(root):
        if only and cid != only:
            continue
        defects = check_chapter(root, cid, en_name)
        if defects:
            failed += 1
            print(f"FAIL {cid}")
            for d in defects:
                print(f"  {d}")
        else:
            print(f"ok   {cid}")
    if only and failed == 0 and not any(cid == only for cid, _ in chapters(root)):
        print(f"loop: no such chapter {only}", file=sys.stderr)
        return 2
    return 1 if failed else 0


def cmd_blob(root, cid):
    match = [(c, name) for c, name in chapters(root) if c == cid]
    if not match:
        print(f"loop: no such chapter {cid}", file=sys.stderr)
        return 2
    _, en_name = match[0]
    en, ja = pair(root, en_name)
    if not en.is_file() or not ja.is_file():
        print(f"loop: missing en/ja for {cid}", file=sys.stderr)
        return 1
    print(json.dumps({"en": blob(root, en), "ja": blob(root, ja)}, indent=2))
    return 0


def cmd_status(root):
    print(f"{'chapter':<24} {'mechanical':<12} {'score':<10} {'doc':<8} file")
    for cid, en_name in chapters(root):
        defects = check_chapter(root, cid, en_name)
        mech = "ok" if not defects else "FAIL"
        state, path, data = score_state(root, cid, en_name)
        doc = "-"
        if state == "current":
            doc = "yes" if doc_measured(data) else "partial"
        rel = ""
        if path is not None:
            rel = str(path.relative_to(root))
        print(f"{cid:<24} {mech:<12} {state:<10} {doc:<8} {rel}")
    return 0


def mean(values):
    if not values:
        return None
    return round(sum(values) / len(values), 2)


def cmd_pass(root, record):
    rows = chapters(root)
    mech_failed = []
    gaps = []
    used = []
    for cid, en_name in rows:
        defects = check_chapter(root, cid, en_name)
        if defects:
            mech_failed.append(cid)
        state, path, data = score_state(root, cid, en_name)
        if state != "current" or not doc_measured(data):
            gaps.append(f"{cid} ({state})")
        else:
            used.append((cid, data))
    print(f"chapters {len(used)}/{len(rows)} have a current doc score")
    if mech_failed:
        print("mechanical FAIL: " + ", ".join(mech_failed))
    if gaps:
        print("not in this pass:")
        for g in gaps:
            print(f"  {g}")
    dimensions = {}
    for name in DIMS:
        values = []
        for _, data in used:
            row = data["dimensions"][name]
            if row["measured"] is True:
                values.append(row["score"])
        dimensions[name] = {
            "score": mean(values),
            "chapters_measured": len(values),
            "chapters_required": len(rows),
        }
        shown = "null" if dimensions[name]["score"] is None else dimensions[name]["score"]
        print(
            f"  {name:<22} {shown}  "
            f"({len(values)}/{len(rows)} chapters)"
        )
    if mech_failed:
        return 1
    if gaps:
        return 2
    if record:
        day = os.environ.get("BOOK_REVIEW_DATE", "")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            print(
                "loop: pass --record needs BOOK_REVIEW_DATE=YYYY-MM-DD",
                file=sys.stderr,
            )
            return 2
        out_dir = root / "eval" / "book-review" / "scores" / "passes"
        out_dir.mkdir(parents=True, exist_ok=True)
        existing = sorted(out_dir.glob(f"{day}-r*.json"))
        n = len(existing) + 1
        out = out_dir / f"{day}-r{n}.json"
        payload = {
            "unit": "pass",
            "date": day,
            "chapters": [cid for cid, _ in used],
            "dimensions": dimensions,
            "notes": "Mean of current chapter scores. Unmeasured chapter dimensions are omitted from that dimension's mean.",
        }
        out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        print(f"recorded {out.relative_to(root)}")
    return 0


def main(argv):
    root = repo_root()
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    cmd = argv[1]
    if cmd == "check":
        only = argv[2] if len(argv) > 2 else None
        return cmd_check(root, only)
    if cmd == "blob":
        if len(argv) != 3:
            print("usage: loop.py blob <chapter_id>", file=sys.stderr)
            return 2
        return cmd_blob(root, argv[2])
    if cmd == "status":
        return cmd_status(root)
    if cmd == "pass":
        record = "--record" in argv[2:]
        return cmd_pass(root, record)
    print(f"loop: unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

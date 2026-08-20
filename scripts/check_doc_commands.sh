#!/usr/bin/env bash
# Every command a document SHOWS a reader must name things that exist.
#
# `check_doc_path_citations.sh` covers backticked paths in prose. It does not
# look inside fenced blocks, and that is where the commands live -- so the
# getting-started chapter could tell a newcomer to run
#
#     curl -fsSL https://.../main/scripts/installer.sh | bash
#     bash scripts/install.sh
#
# when the installer is `install/install.sh` and neither of those paths exists.
# Both had drifted from README.md and docs/install.md, which are correct. The
# reader most likely to be stopped by this is the one with the least context.
#
# Checked per fenced bash/console block:
#   pkf run <task>                     the task exists in Taskfile.pkl
#   scripts|tests|eval|install/....sh  the file exists
#   VIBE_*=                            something in the tree reads it
#
# Not checked: whether the command SUCCEEDS. That needs a built compiler and a
# network, and this is meant to stay a fast text gate. It answers the narrower
# question -- does this name a thing that exists -- which is what the failures
# above were.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 - "$@" <<'PY'
import os, re, sys

roots = ["docs", "book", "AGENTS.md", "README.md"]
files = []
for r in roots:
    if os.path.isfile(r):
        files.append(r)
    else:
        for dp, _, fn in os.walk(r):
            if "archive" in dp:
                continue
            files += [os.path.join(dp, f) for f in fn if f.endswith(".md")]

tf = open("Taskfile.pkl", encoding="utf-8").read()
tasks = set(re.findall(r'name\s*=\s*"([a-z0-9:-]+)"', tf)) | set(re.findall(r'scriptTask\("([a-z0-9:-]+)"', tf))
# Read the tree directly rather than shelling out to grep. Under pkf's task
# sandbox the subprocess came back empty, so every VIBE_* lookup failed and 38
# live variables were reported as unread -- loudly wrong rather than silently,
# but wrong. Pure Python has no such dependency.
ENVPAT = re.compile(r'VIBE_[A-Z0-9_]+')
read_env = set()
for root in ("scripts", "lib", "tests", "eval", "install"):
    for dp, _, fn in os.walk(root):
        for name in fn:
            if not name.endswith((".sh", ".mjs", ".js", ".vibe", ".vibex", ".pkl", ".ts", ".toml", ".md")):
                continue
            try:
                read_env |= set(ENVPAT.findall(open(os.path.join(dp, name), encoding="utf-8", errors="replace").read()))
            except OSError:
                pass
try:
    read_env |= set(ENVPAT.findall(open("Taskfile.pkl", encoding="utf-8").read()))
except OSError:
    pass
if len(read_env) < 20:
    print(f"check-doc-commands: FAIL: only {len(read_env)} VIBE_* names found in the tree -- "
          "the scan is not seeing the sources, so every lookup below would be a false failure",
          file=sys.stderr)
    sys.exit(1)

# Exceptions, with a reason each. See the file's header for what may go in it.
allow = set()
alw = "scripts/doc_commands_allowlist.tsv"
if os.path.exists(alw):
    for line in open(alw, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[2].strip():
            allow.add((parts[0], parts[1]))

fails = []
checked = 0
for f in sorted(files):
    lines = open(f, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        if re.match(r'\s*```(bash|console|sh)\b', lines[i]):
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                ln, line = i + 1, lines[i].strip().lstrip("$ ").strip()
                if not line.startswith("#"):
                    # A retired runner is a command that cannot run, which is
                    # the same failure as a path that does not exist -- and it
                    # is how a whole retired section stayed in docs/coverage.md
                    # under a banner claiming it had been removed (#2138 review).
                    m = re.match(r'(just|moon|cargo run --bin vibe)\b', line)
                    if m:
                        checked += 1
                        tool = m.group(1)
                        if (f, tool) not in allow:
                            fails.append((f, ln, f"`{tool}` -- retired runner; `just` was replaced by "
                                                 f"`pkf` and the MoonBit host went in #594"))
                    for m in re.finditer(r'\bpkf run ((?:--[a-z-]+ )*)([a-z0-9:-]+)', line):
                        t = m.group(2); checked += 1
                        if t not in tasks and (f, t) not in allow:
                            fails.append((f, ln, f"`pkf run {t}` -- no such task in Taskfile.pkl"))
                    for m in re.finditer(r'(?<![\w/.-])((?:scripts|tests|eval|install)/[A-Za-z0-9_./-]+\.(?:sh|mjs|vibex))', line):
                        p = m.group(1); checked += 1
                        if not os.path.exists(p) and (f, p) not in allow:
                            fails.append((f, ln, f"`{p}` -- no such file"))
                    for m in re.finditer(r'\b(VIBE_[A-Z0-9_]+)=', line):
                        e = m.group(1); checked += 1
                        if e not in read_env and (f, e) not in allow:
                            fails.append((f, ln, f"`{e}` -- nothing in the tree reads this"))
                i += 1
        i += 1

for f, ln, why in fails:
    print(f"check-doc-commands: FAIL: {f}:{ln}: {why}", file=sys.stderr)
if fails:
    print(f"check-doc-commands: {len(fails)} stale reference(s) in documented commands", file=sys.stderr)
    sys.exit(1)
if checked < 40:
    print(f"check-doc-commands: FAIL: only {checked} references extracted -- the blocks moved or "
          "changed shape, so this gate is asserting nothing", file=sys.stderr)
    sys.exit(1)
print(f"check-doc-commands: ok ({checked} references in documented commands all resolve)")
PY

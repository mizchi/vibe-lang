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

# Every .md under docs/ and book/, every .md at the repository root, and every
# README.md ANYWHERE in the tree.
#
# The first version of this scanner stopped at docs/, book/, AGENTS.md and
# README.md, and the review found what that missed: lib/@vibe/compiler/README.md
# told the reader to run `just release-check`, in an executable bash fence, with
# no Justfile in the repository since the runner moved to pkfire. A README is
# the document a reader hits FIRST when they open a directory -- exactly the
# audience this gate is for -- so the gate reporting success while those sat
# there was the same failure it was written to catch, one level out.
#
# Widening it turned up 11 more, including a whole test directory
# (tests/integration-deno) whose commands, tasks and target artifact had all
# been retired with the MoonBit host.
skip_dirs = {".git", "_build", "node_modules", "dist", "target", "archive", ".direnv"}
files = []
for r in ("docs", "book"):
    for dp, dn, fn in os.walk(r):
        dn[:] = [d for d in dn if d not in skip_dirs]
        if "archive" in dp:
            continue
        files += [os.path.join(dp, f) for f in fn if f.endswith(".md")]
files += [f for f in os.listdir(".") if f.endswith(".md") and os.path.isfile(f)]
for dp, dn, fn in os.walk("."):
    dn[:] = [d for d in dn if d not in skip_dirs]
    if "README.md" in fn:
        files.append(os.path.normpath(os.path.join(dp, "README.md")))
files = sorted(set(os.path.normpath(f) for f in files))

tf = open("Taskfile.pkl", encoding="utf-8").read()
# Task names may contain '_' (experimental_wasmtime_stack_switching). A
# character class that stops at the underscore truncates on BOTH sides -- the
# Taskfile scan never learns the name and the doc scan cites a prefix nobody
# wrote -- so a task that exists is reported missing under a name that is not
# in either file.
NAMECHARS = r'[a-z0-9_:-]+'
tasks = set(re.findall(r'name\s*=\s*"(' + NAMECHARS + r')"', tf)) | set(re.findall(r'scriptTask\("(' + NAMECHARS + r')"', tf))
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
# The CLI's own verbs, taken from the launcher that dispatches them
# (runtime/vibe): the `# Subcommands:` block `vibe help` prints, plus the arms
# of the dispatch `case`, since a few verbs are dispatched without being
# advertised (`hash`). A doc naming a verb outside that union names a command
# the CLI answers with `unknown command`.
#
# This is the largest class the gate found once it could see all the docs:
# docs/cli-commands.md documents `ide`, `finalize`, `history`, `lsif`,
# `expand`, `save`, `apply`, `clean`, `init`, `precompile`, `update-lock` and
# `explain-import`, and the CLI rejects every one (measured 2026-08-20 against
# an installed toolchain).
launcher = open("runtime/vibe", encoding="utf-8").read()
help_block = re.search(r'^# Subcommands:.*?^#   vibe help ', launcher, re.S | re.M)
verbs = set(re.findall(r'^#   vibe ([a-z][a-z0-9-]*)', help_block.group(0), re.M)) if help_block else set()
case_block = re.search(r'^case "\$cmd" in$(.*?)^esac$', launcher, re.S | re.M)
if case_block:
    for arm in re.findall(r'^  ([a-z][a-z0-9|-]*)\)', case_block.group(1), re.M):
        verbs |= {v for v in arm.split("|") if v}
# A parse that finds nothing would pass every doc silently. Fail loudly instead.
if len(verbs) < 20:
    print(f"check-doc-commands: FAIL: read only {len(verbs)} verbs from runtime/vibe -- the "
          f"launcher's shape changed and this gate can no longer see its subject", file=sys.stderr)
    sys.exit(1)

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

# A proper fence state machine. The first version matched an OPENING fence and
# then read to the next line starting with ```, which silently inverted parity
# for the rest of any file containing a ```vibe (or ```json, ```output) block:
# that block's CLOSING ``` is a bare fence, so it was read as an opener, prose
# after it was scanned as commands, and the real bash block after THAT was
# skipped as if it were prose. docs/cli-commands.md -- the command reference --
# was scanned inside-out this way, and its `vibe update-lock` example went
# unreported while sentences elsewhere were reported as commands.
#
# Now: every ``` toggles, the opener's tag is remembered, and lines are checked
# only inside a fence tagged bash / console / sh / nothing. Untagged is included
# because cli-commands.md writes its examples in bare fences.
SHELLY = {"", "bash", "console", "sh", "shell"}

def shell_lines(path):
    """Yield (lineno, stripped_line) for lines inside shell-ish fences."""
    tag = None          # None = outside a fence
    for n, raw in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        m = re.match(r'\s*```+\s*([A-Za-z0-9_+-]*)', raw)
        if m:
            if tag is None:
                tag = m.group(1).lower()
            else:
                tag = None
            continue
        if tag in SHELLY:
            line = raw.strip()
            if line.startswith("$ "):
                line = line[2:].strip()
            if line and not line.startswith("#"):
                yield n, line

for f in sorted(files):
    for ln, line in shell_lines(f):
        # A retired runner is a command that cannot run, which is the same
        # failure as a path that does not exist -- and it is how a whole retired
        # section stayed in docs/coverage.md under a banner claiming it had been
        # removed (#2138 review).
        m = re.match(r'(just|moon|cargo run --bin vibe)\b', line)
        if m:
            checked += 1
            tool = m.group(1)
            if (f, tool) not in allow:
                fails.append((f, ln, f"`{tool}` -- retired runner; `just` was replaced by "
                                     f"`pkf` and the MoonBit host went in #594"))
        for m in re.finditer(r'\bpkf run ((?:--[a-z-]+ )*)(' + NAMECHARS + r')', line):
            t = m.group(2); checked += 1
            if t not in tasks and (f, t) not in allow:
                fails.append((f, ln, f"`pkf run {t}` -- no such task in Taskfile.pkl"))
        # `pkf run run` is scripts/vibe_run.sh, which takes ONE .vibex
        # executable root -- not a CLI subcommand. Documents inherited the
        # retired MoonBit-host `just run <subcommand>` shape through a
        # mechanical just->pkf rename, leaving `pkf run run -- compile ...`,
        # `-- test ...`, `-- ide ...` forms that cannot work: the first
        # argument is read as a path. The other checks cannot see this,
        # because the words after `--` are a verb, not a task name.
        m = re.match(r'pkf run run -- (?:--[a-z-]+ )*([A-Za-z0-9_./@-]+)', line)
        if m:
            arg = m.group(1); checked += 1
            if not arg.endswith(".vibex") and (f, "pkf run run") not in allow:
                extra = ("; that is a CLI subcommand, and `pkf run run` takes a path"
                         if "/" not in arg and "." not in arg else "")
                fails.append((f, ln, f"`pkf run run -- {arg}` -- `pkf run run` is "
                                     f"scripts/vibe_run.sh and requires a .vibex "
                                     f"executable root{extra}"))
        for m in re.finditer(r'(?<![\w/.-])((?:scripts|tests|eval|install)/[A-Za-z0-9_./-]+\.(?:sh|mjs|vibex))', line):
            pth = m.group(1); checked += 1
            if not os.path.exists(pth) and (f, pth) not in allow:
                fails.append((f, ln, f"`{pth}` -- no such file"))
        # Anchored at line start. Untagged fences carry prose too -- "vibe
        # treats X as Y", "vibe is a byte string" -- and an unanchored match
        # read every one of those as a command. A command starts its line.
        m = re.match(r'vibe (?:--[a-z-]+ )*([a-z][a-z0-9-]*)', line)
        if m:
            v = m.group(1); checked += 1
            if v not in verbs and (f, v) not in allow:
                fails.append((f, ln, f"`vibe {v}` -- no such command; the CLI answers "
                                     f"`unknown command: {v}`"))
        for m in re.finditer(r'\b(VIBE_[A-Z0-9_]+)=', line):
            e = m.group(1); checked += 1
            if e not in read_env and (f, e) not in allow:
                fails.append((f, ln, f"`{e}` -- nothing in the tree reads this"))

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

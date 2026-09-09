#!/usr/bin/env bash
# Every gate must be REACHABLE from a workflow, or it is indistinguishable from
# a passing one (#2580).
#
# That is not hypothetical. Three gates went dark, and none of the three was
# found by a gate:
#
#   lint_tracked_experiment_names.sh  ran nowhere for weeks -- AGENTS.md records
#                                     it ("release-check has no CI job")
#   check_task_inputs.sh              red since #2473, unnoticed until #2577
#   check_portable_boundary.sh        asserting a two-ADR-old shape, reporting
#                                     "missing expected pure boundary" for files
#                                     that no longer exist
#
# #2577 audited this BY HAND and #2579 wired the last of them. The audit is not
# repeatable, so the next gate added with no workflow path is invisible again on
# the day it lands. This makes the question answerable by a script.
#
# WHY THIS IS DECIDABLE, where "does this shell script reach the compiler" is
# not: reachability here is a LEXICAL NAME GRAPH. A workflow names a task or a
# script; a task names a script or other tasks; a script names other scripts.
# AGENTS.md (#2248) is explicit that shell DATAFLOW does not converge for a
# scanner -- this does not need dataflow. Two properties of the tree, both
# measured, are what make the lexical read sound:
#
#   1. No `pkf run` anywhere takes a computed task name. All are literals.
#   2. Script invocations vary the DIRECTORY (`"$SCRIPT_DIR/x.sh"`,
#      `"$PROJECT_ROOT/scripts/x.sh"`) but never the BASENAME. So matching the
#      basename in an invocation position resolves them all.
#
# Both are re-checked on every run: a computed task name or a computed basename
# FAILS rather than being skipped, because silence and "unchecked" are
# indistinguishable and that is the whole defect this gate exists for.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${VIBE_GATE_WIRING_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$ROOT"

exec python3 - "$ROOT" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
os.chdir(root)

SELF = "check_gate_wiring.sh"
SELF_TEST = "check_gate_wiring_test.sh"
ALLOWLIST = "scripts/gate_wiring_allowlist.txt"

def read(p):
    try:
        with open(p, encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return ""

def listdir(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []

# ---- the corpus: EVERY gate script, this one included.
#
# A gate must not be able to see itself (#2138), and the precise reading matters
# here. What must be excluded is this file's TEXT AS EVIDENCE: it names scripts
# and task names in its own comments and regex literals, and its self-test
# carries deliberate fixtures, so reading either as an edge would let it certify
# a wire that does not exist. Excluding it from the CORPUS instead would be a
# different thing entirely -- it would exempt this gate from the very property
# it enforces, and it could then go dark exactly like the three that did.
# So: in the corpus, out of the edge sources (see SKIP_AS_SOURCE below).
gates = [f for f in listdir("scripts")
         if re.match(r"^(check|lint)_.*\.sh$", f) and not f.endswith("_test.sh")]
corpus = list(gates)
SKIP_AS_SOURCE = {SELF, SELF_TEST}

if not corpus:
    print("[gate-wiring] FAIL: no gate scripts found under scripts/ -- the corpus went empty, "
          "which is the shape that lets a checker pass while looking at nothing", file=sys.stderr)
    sys.exit(1)

# ---- allowlist: a gate that is genuinely local-only must SAY SO, in writing,
# with a reason on the same line. Same shape as tracked_experiment_name_allowlist.txt.
allow = {}
for line in read(ALLOWLIST).splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, _, reason = line.partition(" ")
    allow[name] = reason.strip()

# ---- nodes we can walk into
def strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

SH_INVOKE = re.compile(
    r"""(?:^|[;&|(]|\bbash\b|\bsh\b|\bsource\b|\bexec\b|^\s*\.\s)"""
    r"""[^\n;&|]*?([A-Za-z0-9_.-]+\.sh)\b""", re.M)
ANY_SH = re.compile(r"\b([A-Za-z0-9_.-]+\.sh)\b")
# Capture the whole token INCLUDING any quotes, then strip them. Excluding the
# quote characters from the class instead makes `pkf run "$X"` match nothing at
# all -- so the computed name it exists to catch would be skipped in silence,
# which is exactly the failure being guarded against. (Caught by the self-test's
# red 3 on the first draft.)
PKF_RUN = re.compile(r"pkf\s+run\s+(\S+)")

def _unquote(tok):
    return tok.strip("\"'`")

def invoked_scripts(text):
    return set(SH_INVOKE.findall(strip_comments(text)))

def named_tasks(text):
    return {t for t in (_unquote(x) for x in PKF_RUN.findall(strip_comments(text)))
            if t and "$" not in t and t != "--"}

# ---- unresolvable references FAIL. Silence is "unchecked", not "safe".
unresolvable = []
def check_resolvable(rel, text):
    body = strip_comments(text)
    for m in PKF_RUN.finditer(body):
        name = _unquote(m.group(1))
        if "$" in name or name in ("--", ""):
            unresolvable.append(f"{rel}: `pkf run {name}` names a computed task; this scanner "
                                f"cannot resolve it, and skipping it would silently unreach every "
                                f"gate behind it -- spell the task name literally")
    # a computed BASENAME, e.g. `bash "$dir/$name.sh"`
    for m in re.finditer(r"""\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\.sh\b""", body):
        unresolvable.append(f"{rel}: `{m.group(0)}` computes a script BASENAME; this scanner "
                            f"resolves by basename, so spell it literally")

# ---- Taskfile: task name -> body, and local binding -> task name
taskfile = read("Taskfile.pkl")
local_to_task = dict(re.findall(
    r"local\s+(\w+)\s*=\s*new Task\s*\{\s*\n\s*name\s*=\s*\"([^\"]+)\"", taskfile))
task_bodies = {}
for m in re.finditer(r"local\s+(\w+)\s*=\s*new Task\s*\{(.*?)\n\}", taskfile, re.S):
    local, body = m.group(1), m.group(2)
    nm = re.search(r'name\s*=\s*"([^"]+)"', body)
    if nm:
        task_bodies[nm.group(1)] = body

# ---- roots: the workflows
workflows = [os.path.join(".github/workflows", f)
             for f in listdir(".github/workflows") if f.endswith((".yml", ".yaml"))]
if not workflows:
    print("[gate-wiring] FAIL: no workflows found under .github/workflows -- with no roots "
          "every gate would report as unreachable, which is a broken scan, not a finding",
          file=sys.stderr)
    sys.exit(1)

reached_scripts = set()
pending_scripts = []
pending_tasks = []

for wf in workflows:
    text = read(wf)
    check_resolvable(wf, text)
    for s in invoked_scripts(text):
        pending_scripts.append(s)
    for t in named_tasks(text):
        pending_tasks.append(t)

# ---- walk the task graph
seen_tasks = set()
while pending_tasks:
    t = pending_tasks.pop()
    if t in seen_tasks:
        continue
    seen_tasks.add(t)
    body = task_bodies.get(t)
    if body is None:
        # A workflow names a task the Taskfile does not define: that is a broken
        # wire, and reporting it as "no gates behind it" would hide the break.
        unresolvable.append(f".github/workflows: `pkf run {t}` names no task in Taskfile.pkl")
        continue
    check_resolvable(f"Taskfile.pkl task {t}", body)
    for s in ANY_SH.findall(body):
        pending_scripts.append(s)
    for local in re.findall(r"\b(\w+)\b", body):
        if local in local_to_task:
            pending_tasks.append(local_to_task[local])

# ---- walk the script graph, transitively, anywhere in the tree
by_basename = {}
for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "_build", "target")]
    for f in filenames:
        if f.endswith(".sh"):
            by_basename.setdefault(f, os.path.join(dirpath, f).lstrip("./"))

while pending_scripts:
    s = pending_scripts.pop()
    if s in reached_scripts:
        continue
    reached_scripts.add(s)
    path = by_basename.get(s)
    if not path or s in SKIP_AS_SOURCE:
        # #2138: this gate's own text, and its self-test's fixtures, are not
        # evidence of a wire. Reached (so it counts as wired), never read.
        continue
    text = read(path)
    check_resolvable(path, text)
    for nxt in invoked_scripts(text):
        if nxt != s:  # a script naming itself in its own message is not an edge
            pending_scripts.append(nxt)

# ---- verdict
dark = [g for g in corpus if g not in reached_scripts and g not in allow]
stale_allow = [g for g in allow if g in reached_scripts]
missing_allow = [g for g in allow if g not in gates]

problems = []
if unresolvable:
    problems.append(("references this scanner cannot resolve (unresolved is UNCHECKED, "
                     "not safe -- #2248)", sorted(set(unresolvable))))
if dark:
    problems.append(("gate scripts no workflow reaches -- they run nowhere, which is "
                     "indistinguishable from passing",
                     [f"  scripts/{g}" for g in dark]))
if stale_allow:
    problems.append(("allowlisted as local-only but now REACHED -- delete the row, or the "
                     "allowlist becomes a place gates hide",
                     [f"  {g}" for g in stale_allow]))
if missing_allow:
    problems.append(("allowlisted but no such gate script exists",
                     [f"  {g}" for g in missing_allow]))

if problems:
    print("[gate-wiring] FAIL:", file=sys.stderr)
    for title, lines in problems:
        print(f"  {title}:", file=sys.stderr)
        for l in lines:
            print(f"  {l}" if not l.startswith("  ") else l, file=sys.stderr)
    sys.exit(1)

print(f"[gate-wiring] ok ({len(corpus)} gate script(s) reachable from "
      f"{len(workflows)} workflow(s); {len(allow)} allowlisted local-only)")
PYEOF

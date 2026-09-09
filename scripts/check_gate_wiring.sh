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

# SCOPE, stated so it is a boundary and not an oversight: `scripts/check_*.sh`
# and `scripts/lint_*.sh`, which is what #2580 defines. The repo also has 27
# `*_gate.sh` scripts (compiler_gate.sh, minify_gate.sh, the
# test_*_component_gate.sh family) that this does NOT cover, so an unwired one
# there is still invisible. Raised by Codex on #2591 and carried to its own
# issue rather than widened here: several would need investigation or an
# allowlist row each, which is a different change from installing the check.

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

# EVERY gate self-test is excluded as an edge source, not just this one's
# (Codex P1 on #2591). A self-test names its production gate because it RUNS it
# against mutation fixtures -- that is a red/green harness, not evidence the
# gate runs against the checkout. Left in, removing `check_portable_boundary.sh`
# from the workflow would leave `check_portable_boundary_test.sh` still naming
# it, and the gate would report it reached: precisely the dark-gate case this
# exists to catch, certified by the thing that proves nothing about CI.
SKIP_AS_SOURCE = {f for f in listdir("scripts") if f.endswith("_test.sh")}
SKIP_AS_SOURCE.add(SELF)

if not corpus:
    print("[gate-wiring] FAIL: no gate scripts found under scripts/ -- the corpus went empty, "
          "which is the shape that lets a checker pass while looking at nothing", file=sys.stderr)
    sys.exit(1)

# ---- allowlist: a gate that is genuinely local-only must SAY SO, in writing,
# with a reason on the same line. Same shape as tracked_experiment_name_allowlist.txt.
allow = {}
no_reason = []
for line in read(ALLOWLIST).splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    name, _, reason = line.partition(" ")
    reason = reason.strip()
    if not reason:
        # The row is meant to be a written admission. Accepting a bare filename
        # would let a gate leave enforcement with no justification at all
        # (Codex P2 on #2591).
        no_reason.append(name)
    allow[name] = reason

# ---- nodes we can walk into
def strip_comments(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

# An edge needs an actual RUNNER before the path. The first draft also accepted
# start-of-line followed by arbitrary text, so any non-comment line mentioning a
# basename counted -- `echo "run bash scripts/check_dark.sh"` in a reachable
# wrapper certified a wire that does not exist (Codex P1 on #2591). A runner
# word, optional flags/env/quotes, an optional computed or literal directory,
# then the basename.
SH_INVOKE = re.compile(
    r"""(?:\bbash\b|\bsh\b|\bsource\b|\bexec\b|(?:^|[;&|(])\s*\.)"""
    r"""[^\n;&|]*?([A-Za-z0-9_.-]+\.sh)\b""", re.M)

# ...and a line whose command EMITS text is not running anything. This is what
# separates `bash scripts/x.sh` from `echo "... bash scripts/x.sh"`.
EMITS = re.compile(r"^\s*(echo|printf|cat|:|#)\b")

# A DYNAMIC invocation: a runner applied to a whole path this scanner cannot
# read, e.g. compiler_gate.sh's `script="$(gate_lane_script "$lane")"` followed
# by `bash "$script"`. Resolving that needs shell dataflow, which #2248 says
# does not converge for a scanner -- and the rule there is to remove the
# structure that needs it, not to chase it.
#
# So the structure removed is the SILENCE: such a line must be accompanied by a
# `# gate-wiring: reaches <path>` directive in the same file, declaring what it
# runs. The declaration is lexical, reviewable next to the code, and CHECKED --
# a path that does not exist fails. Without one the line fails outright, because
# skipping it would silently unreach everything behind the dispatcher.
# Only a dynamic RUN counts, not a dynamic `source`. Sourcing brings a
# library's functions into scope -- `source "$GATES_LIB"` in each lane
# entrypoint -- and a library is not a gate; whatever it would run is written in
# its own file, which is reached on its own terms. Demanding a directive for
# every dynamic source would make the rule noisy without closing anything.
DYNAMIC_INVOKE = re.compile(
    r"""^\s*(?:\bbash\b|\bsh\b|\bexec\b)\s+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?\s*$""",
    re.M)
REACHES = re.compile(r"^\s*#\s*gate-wiring:\s*reaches\s+(\S+)\s*$", re.M)
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
    out = set()
    for line in strip_comments(text).splitlines():
        if EMITS.match(line):
            continue
        out |= set(SH_INVOKE.findall(line))
    return out

def named_tasks(text):
    return {t for t in (_unquote(x) for x in PKF_RUN.findall(strip_comments(text)))
            if t and "$" not in t and t != "--"}

# ---- unresolvable references FAIL. Silence is "unchecked", not "safe".
unresolvable = []
declared_edges = []

def check_resolvable(rel, text):
    body = strip_comments(text)
    # Directives are comments, so they are read from the RAW text.
    declared = REACHES.findall(text)
    for d in declared:
        if not os.path.isfile(d):
            unresolvable.append(f"{rel}: `# gate-wiring: reaches {d}` names no such file")
        else:
            declared_edges.append(os.path.basename(d))
    for m in DYNAMIC_INVOKE.finditer(body):
        if not declared:
            unresolvable.append(
                f"{rel}: `{m.group(0).strip()}` runs a path this scanner cannot read, and the file "
                f"declares nothing -- add `# gate-wiring: reaches <path>` lines naming what it runs, "
                f"or skipping it would silently unreach every gate behind it")
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

# Tasks built through the `scriptTask(name, script)` helper are just as real,
# and parsing only `new Task { ... }` reported them as UNDEFINED -- so a
# workflow invoking one would have failed the check and marked its script dark
# (Codex P2 on #2591).
for m in re.finditer(r"""(?:local\s+(\w+)\s*=\s*)?scriptTask\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)""", taskfile):
    local, task_name, script = m.group(1), m.group(2), m.group(3)
    task_bodies.setdefault(task_name, f'cmd = "bash {script}"')
    if local:
        local_to_task.setdefault(local, task_name)

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
# A basename can name MORE THAN ONE file, and every one of them must be read.
# `tests/gates/{bootstrap,early,mid,late}/run.sh` are four files with one
# basename, and compiler_gate.sh invokes them as
# `bash "$ROOT_DIR/tests/gates/$lane/run.sh"` -- a computed DIRECTORY with a
# literal basename, which is the shape this scanner resolves. Keeping only the
# first match made the answer depend on os.walk ORDER: it passed locally and
# reported five gates dark in CI, because a different order read a different
# `run.sh`. A gate that answers differently on two machines is worse than no
# gate, so: all copies, sorted, every one read.
# NOTE: do not wrap os.walk() in sorted(). That materializes the whole walk
# before the loop body runs, so pruning `dirnames[:]` has no effect and _build
# (which holds whole COPIES of the tree, from seed rebuilds) gets scanned.
# Collect first, sort after.
by_basename = {}
for dirpath, dirnames, filenames in os.walk("."):
    dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "_build", "target")]
    for f in filenames:
        if f.endswith(".sh"):
            by_basename.setdefault(f, []).append(os.path.join(dirpath, f).lstrip("./"))
for k in by_basename:
    by_basename[k].sort()

while pending_scripts:
    s = pending_scripts.pop()
    if s in reached_scripts:
        continue
    reached_scripts.add(s)
    if s in SKIP_AS_SOURCE:
        # #2138: this gate's own text, and its self-test's fixtures, are not
        # evidence of a wire. Reached (so it counts as wired), never read.
        continue
    for path in by_basename.get(s, []):
        text = read(path)
        before = len(declared_edges)
        check_resolvable(path, text)
        for nxt in declared_edges[before:]:
            pending_scripts.append(nxt)
        for nxt in invoked_scripts(text):
            if nxt != s:  # a script naming itself in its own message is not an edge
                pending_scripts.append(nxt)

# ---- verdict
dark = [g for g in corpus if g not in reached_scripts and g not in allow]
stale_allow = [g for g in allow if g in reached_scripts]
missing_allow = [g for g in allow if g not in gates]

problems = []
if no_reason:
    problems.append(("allowlist rows with no reason -- a row here is a written admission, "
                     "so say why on the same line",
                     [f"  {g}" for g in sorted(no_reason)]))
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

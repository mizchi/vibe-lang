#!/usr/bin/env bash
# A task that runs the compiler must have the compiler in its cache key.
#
# `scriptTask(...)` gets `vibeSources` + `scriptSources` by default and is
# always safe. The risk is a hand-written `new Task { ... }`, where spelling
# `inputs` out is usually done to ADD something (a document, a fixture) and it
# is easy to end up REPLACING the defaults instead. The result is a task that
# still passes, from cache, after the very change it exists to catch.
#
# This has now happened three times on one branch -- twice by me, once caught in
# review -- which is what makes it a gate rather than a note. Inputs may
# over-approximate (a needless re-run costs time); they may never
# under-approximate (that costs a wrong answer).
#
# The rule: if a task's command reaches the compiler, its inputs must include
# `vibeSources`, or it must set `cache = false`.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 - "$@" <<'PY'
import re, sys, os

# Overridable so the self-test can drive synthetic task blocks.
TASKFILE = os.environ.get("TASK_INPUTS_TASKFILE", "Taskfile.pkl")
src = open(TASKFILE, encoding="utf-8").read()

# A script "reaches the compiler" when it EXECUTES one of these, not when it
# mentions one. A first cut matched any occurrence of `stage2` and flagged six
# tasks that were fine: the word appears in a comment, in a JSON key
# (`stage2.wasm bytes`), and inside a test fixture's expected output. A gate
# with that false-positive rate teaches people to ignore it, so the match is
# anchored to an invocation.
# The `scripts/` prefix is required, not decoration: without it this detector
# matched the tool names inside its OWN regex literal and flagged itself. Every
# real invocation in the tree names the script by path.
TOOL_RE = re.compile(
    r"scripts/(?:run_wasm_vibe_host_runner|generations|vibe_cli|vibe_test|"
    r"vibe_run|ensure_generated|build_cli_wasm|build_cli_core)")
# The line must also look like it is RUNNING something.
EXEC_RE = re.compile(r"\b(bash|sh|env|exec|node|spawnSync|spawn|execSync|execFileSync)\b")
COMMENT_RE = re.compile(r"^\s*(#|//|\*)")

def reaches_compiler(script):
    try:
        lines = open(script, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return False
    for line in lines:
        if COMMENT_RE.match(line):
            continue
        if TOOL_RE.search(line) and EXEC_RE.search(line):
            return True
    return False

# Hand-written `new Task { ... }` blocks only; scriptTask() one-liners inherit
# the safe defaults.
fails = []
checked = 0
for m in re.finditer(r"new Task \{", src):
    start = m.start()
    depth, k = 0, start + len("new Task ") - 1
    while True:
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    block = src[start:k + 1]
    name_m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if not name_m:
        continue
    name = name_m.group(1)
    if "inputs" not in block:          # no explicit inputs: nothing was replaced
        continue
    if re.search(r"cache\s*=\s*false", block):
        continue
    # From the COMMAND only. Reading the whole block also picked up scripts
    # named in `inputs`, which a task declares but does not run -- that flagged
    # a self-test whose command touches nothing.
    cmd_m = re.search(r'cmd\s*=\s*(#?)"(.*?)"\1', block, re.S)
    cmd = cmd_m.group(2) if cmd_m else ""
    scripts = re.findall(r'(scripts/[A-Za-z0-9_./-]+\.(?:sh|mjs))', cmd)
    hot = [s for s in scripts if reaches_compiler(s)]
    if not hot:
        continue
    checked += 1
    if "vibeSources" not in block:
        fails.append((name, hot[0]))

for name, script in fails:
    print(f"check-task-inputs: FAIL: task `{name}` runs {script}, which reaches the compiler,",
          file=sys.stderr)
    print("  but its explicit `inputs` do not include `...vibeSources` and it does not set",
          file=sys.stderr)
    print("  `cache = false`. A change under lib/**/*.vibe would replay a cached pass.",
          file=sys.stderr)
    print("  Add `...vibeSources` to the list -- spelling inputs out should ADD to the",
          file=sys.stderr)
    print("  defaults, not replace them.", file=sys.stderr)

if fails:
    sys.exit(1)
print(f"check-task-inputs: ok ({checked} compiler-touching tasks with explicit inputs all key on lib/**)")
PY

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
# The rule: if a cached task's command reaches the compiler, its inputs must
# include `compilerProbeInputs` (selfhost sources + bootstrap seed), or it must
# set `cache = false`.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

python3 - "$@" <<'PY'
import re, sys, os

# Overridable so the self-test can drive synthetic task blocks.
TASKFILE = os.environ.get("TASK_INPUTS_TASKFILE", "Taskfile.pkl")
INPUT_ROOT = os.environ.get("TASK_INPUTS_ROOT", ".")
src = open(TASKFILE, encoding="utf-8").read()

def active_pkl(text):
    """Drop Pkl line comments before checking whether an input is active."""
    return re.sub(r"//.*$", "", text, flags=re.M)

# The shared compiler-probe input set is safe only while it contains both
# halves of the compiler identity: selfhost sources and the bootstrap seed.
probe_inputs_m = re.search(
    r"local\s+compilerProbeInputs(?:\s*:[^=]+)?\s*=\s*new\s*\{(.*?)\}",
    src,
    re.S,
)
probe_inputs_body = active_pkl(probe_inputs_m.group(1)) if probe_inputs_m else ""
probe_inputs_safe = bool(
    probe_inputs_m
    and "vibeSources" in probe_inputs_body
    and '"bootstrap/seed.json"' in probe_inputs_body
)

# scriptTask wrappers are deliberately classified as a group: some execute the
# compiler through several shell layers, which text inspection cannot prove
# individually. The shared factory must therefore carry the complete identity.
script_task_decl = re.search(r"local\s+function\s+scriptTask\b", src)
script_task_inputs = None
if script_task_decl:
    brace = src.find("{", script_task_decl.end())
    depth, end = 0, brace
    while brace >= 0 and end < len(src):
        if src[end] == "{":
            depth += 1
        elif src[end] == "}":
            depth -= 1
            if depth == 0:
                break
        end += 1
    factory_block = src[brace : end + 1] if brace >= 0 and depth == 0 else ""
    script_task_inputs = re.search(r"inputs\s*\{(.*?)\}", factory_block, re.S)
script_task_inputs_body = active_pkl(script_task_inputs.group(1)) if script_task_inputs else ""
script_task_safe = bool(
    script_task_inputs
    and "compilerProbeInputs" in script_task_inputs_body
    and probe_inputs_safe
)
script_task_bad = bool(script_task_decl and not script_task_safe)

# A script "reaches the compiler" when it EXECUTES one of these, not when it
# mentions one. A first cut matched any occurrence of `stage2` and flagged six
# tasks that were fine: the word appears in a comment, in a JSON key
# (`stage2.wasm bytes`), and inside a test fixture's expected output. A gate
# with that false-positive rate teaches people to ignore it, so the match is
# anchored to an invocation.
# The `scripts/` prefix is required, not decoration: without it this detector
# matched the tool names inside its OWN regex literal and flagged itself. Every
# real invocation in the tree names the script by path.
# Any directory, not just scripts/ (#2138 review): a wrapper under
# tests/gates/**/ invokes ensure_generated.sh and the wasm runner exactly the
# way one under scripts/ does, and requiring the `scripts/` prefix missed it.
# A path separator is still required -- that is what keeps this detector from
# matching the tool names inside its own regex literal.
TOOL_RE = re.compile(
    r"[\w./-]+/(?:run_wasm_vibe_host_runner|generations|vibe_cli|vibe_test|"
    r"vibe_run|ensure_generated|build_cli_wasm|build_cli_core)")
# Aggregators dispatch the lane scripts dynamically, so none of the tool names
# above appear in them literally (#2138 review). A task whose command is
# `bash scripts/compiler_gate.sh` runs the compiler as surely as one naming the
# runner, and without these it was classified as touching nothing.
AGGREGATOR_RE = re.compile(
    r"scripts/(?:compiler_gate\.sh|unit_test_runner\.sh|pkfire/gates_shard\.sh|"
    r"test_affected\.sh|coverage_suite\.sh|coverage_corpus\.sh)")
# The line must also look like it is RUNNING something.
EXEC_RE = re.compile(
    r"(?:^|[;&|(\s])(?:bash|sh|env|exec|node|spawnSync|spawn|execSync|execFileSync)(?=\s|\()"
)
COMMENT_RE = re.compile(r"^\s*(#|//|\*)")
SEED_RE = re.compile(r"bootstrap/seed(?:\.json|/compiler\.wasm)")
SCRIPT_PATH_RE = re.compile(r"((?:scripts|tests|eval|bench)/[A-Za-z0-9_./-]+\.(?:sh|mjs))")
SCRIPT_BASENAME_RE = re.compile(r"([A-Za-z0-9_.-]+\.(?:sh|mjs))")
DIRECT_SCRIPT_RE = re.compile(
    r'(?:^|[;&|!(])\s*"?(?:\./|\.\./|\$[A-Za-z_][A-Za-z0-9_]*/|scripts/|tests/|eval/|bench/)'
    r'[^"\s;|]+\.(?:sh|mjs)(?=["\s;|)]|$)'
)

def reaches_compiler(script, seen=None):
    seen = set() if seen is None else seen
    # A checker must not certify itself from regex literals or test fixtures.
    if os.path.normpath(script) == "scripts/check_task_inputs.sh" or script in seen:
        return False
    seen.add(script)
    try:
        path = os.path.join(INPUT_ROOT, script)
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except OSError:
        return False
    for line in lines:
        if COMMENT_RE.match(line):
            continue
        if SEED_RE.search(line) or (TOOL_RE.search(line) and EXEC_RE.search(line)):
            return True
        if not EXEC_RE.search(line) and not DIRECT_SCRIPT_RE.search(line):
            continue
        nested = SCRIPT_PATH_RE.findall(line)
        nested += [os.path.join(os.path.dirname(script), name) for name in SCRIPT_BASENAME_RE.findall(line)]
        for child in nested:
            if child != script and (AGGREGATOR_RE.search(child) or reaches_compiler(child, seen)):
                return True
    return False

# Hand-written `new Task { ... }` blocks only; scriptTask() one-liners inherit
# the complete compiler identity checked above.
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
    active_block = active_pkl(block)
    name_m = re.search(r'name\s*=\s*"([^"]+)"', active_block)
    if not name_m:
        continue
    name = name_m.group(1)
    # A hand-written `new Task` inherits NOTHING, so no `inputs` at all is the
    # worst case, not the safe one: an empty cache key replays the first result
    # after any change (#2138 review). `scriptTask` one-liners are excluded
    # above precisely because they DO inherit the defaults.
    if re.search(r"cache\s*=\s*false", active_block):
        continue
    # From the COMMAND only. Reading the whole block also picked up scripts
    # named in `inputs`, which a task declares but does not run -- that flagged
    # a self-test whose command touches nothing.
    cmd_m = re.search(r'cmd\s*=\s*(#?)"(.*?)"\1', active_block, re.S)
    cmd = cmd_m.group(2) if cmd_m else ""
    scripts = SCRIPT_PATH_RE.findall(cmd)
    hot = [s for s in scripts if AGGREGATOR_RE.search(s) or reaches_compiler(s)]
    if not hot:
        continue
    checked += 1
    inputs_m = re.search(r"inputs\s*\{(.*?)\}", active_block, re.S)
    has_compiler_inputs = bool(
        inputs_m and "compilerProbeInputs" in inputs_m.group(1) and probe_inputs_safe
    )
    if not has_compiler_inputs:
        why = "declares no `inputs` at all" if not inputs_m else "does not include a complete compiler input set"
        fails.append((name, hot[0], why))

for name, script, why in fails:
    print(f"check-task-inputs: FAIL: task `{name}` runs {script}, which reaches the compiler,",
          file=sys.stderr)
    print(f"  but it {why} and does not set `cache = false`. A compiler identity", file=sys.stderr)
    print("  change would replay a cached pass.", file=sys.stderr)
    print("  Add `...compilerProbeInputs` to the list -- spelling inputs out should ADD to the",
          file=sys.stderr)
    print("  defaults, not replace them.", file=sys.stderr)

if script_task_bad:
    print("check-task-inputs: FAIL: scriptTask inputs do not include the complete", file=sys.stderr)
    print("  `...compilerProbeInputs` set; indirect compiler wrappers can replay", file=sys.stderr)
    print("  a cached pass after a bootstrap seed change.", file=sys.stderr)

if fails or script_task_bad:
    sys.exit(1)
print(f"check-task-inputs: ok ({checked} compiler-touching tasks with explicit inputs and scriptTask all key on compiler sources)")
PY

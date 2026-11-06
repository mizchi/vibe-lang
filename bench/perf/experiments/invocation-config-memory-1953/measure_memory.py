"""Compare resident memory checking with common virtual inputs and fixed paths."""

import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline_root", type=Path)
parser.add_argument("candidate_root", type=Path)
parser.add_argument("baseline_wasm", type=Path)
parser.add_argument("candidate_wasm", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
roots = {"a": args.baseline_root.resolve(), "b": args.candidate_root.resolve()}
compilers = {"a": args.baseline_wasm.resolve(), "b": args.candidate_wasm.resolve()}
work = args.output.resolve()
work.mkdir(exist_ok=False)
source = Path(__file__).with_name("memory_check.vibe").read_bytes()
active = work / "active"
runtime = work / "run"
runtime.mkdir()
images = work / "images"
images.mkdir()
runner = roots["b"] / "scripts/run_wasm_vibe_host_runner.sh"
generated = (
    "compiler_sources_bundle.vibe", "cli_adapter_bundle.vibe",
    "selfbuild_runtime_entry_bundle.vibe", "_cli_adapter_module_source.vibe",
    "cache/codegen_fingerprint.vibe",
)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def environment(root):
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_PREOPEN_DIR=str(root), VIBE_IMPORT_ABI="raw", VIBE_RC="0", PWD=str(root))
    return env


receipt = {
    "complete": False,
    "protocol": "Each image contains its checkout's runtime and the identical shared memory_check.vibe. Compilation uses one literal active root/compiler/output path. Every runtime sample starts a fresh Node process at one literal module path, with 128 virtual modules. A cold check precedes 128 resident warm checks; guest Profiler counters delimit each region. Bump RC=0; no Fs authority or persistent cache. A/A controls precede AB/BA/AB pairs for empty and alpha flags. Runs must be isolated from other compiler/test jobs.",
    "benchmark_source_sha256": hashlib.sha256(source).hexdigest(),
    "node_version": subprocess.check_output(["node", "--version"], text=True).strip(),
    "commits": {}, "trees": {}, "compilers": {}, "images": {},
    "aa_controls": [], "runs": [],
}


def save():
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


save()
for lane, root in roots.items():
    subprocess.run(["git", "diff", "--exit-code"], cwd=root, check=True, capture_output=True)
    receipt["commits"][lane] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    receipt["trees"][lane] = subprocess.check_output(["git", "write-tree"], cwd=root, text=True).strip()
    receipt["compilers"][lane] = sha(compilers[lane])
    snapshot = work / ("stored-" + lane)
    snapshot.mkdir()
    subprocess.run(["git", "checkout-index", "--all", "--prefix=" + str(snapshot) + "/"], cwd=root, check=True, capture_output=True)
    for rel in generated:
        dest = snapshot / "lib/@vibe/compiler" / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "lib/@vibe/compiler" / rel, dest)
    (snapshot / "_build").mkdir(exist_ok=True)
    (snapshot / "_build/memory_check.vibe").write_bytes(source)
    shutil.copy2(compilers[lane], snapshot / "_build/compiler.wasm")
    snapshot.rename(active)
    try:
        env = environment(active)
        env.update(VIBE_FS_COMPILE="1", VIBE_INTERNAL_TRUSTED_SOURCE="1",
                   VIBE_EXPERIMENTAL_AST_CACHE="0", VIBE_BUILD_CACHE_DIR=str(active / "_build/compile-cache"))
        (active / "_build/compile-cache").mkdir()
        result = subprocess.run(
            ["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
             str(active / "_build/compiler.wasm"), "_build/memory_check.vibe", "_build/memory_check.wasm", "main"],
            cwd=active, env=env, capture_output=True, text=True, timeout=900,
        )
        (work / ("compile-" + lane + ".log")).write_text(result.stdout + result.stderr)
        output = active / "_build/memory_check.wasm"
        diag = Path(str(output) + ".diag")
        assert result.returncode == 0 and result.stdout.strip() == "0" and output.exists(), (lane, diag.read_text() if diag.exists() else result.stderr[-3000:])
        shutil.copy2(output, images / (lane + ".wasm"))
        receipt["images"][lane] = {"sha256": sha(output), "bytes": output.stat().st_size}
    finally:
        active.rename(snapshot)
    assert snapshot.parent == work and not (snapshot / ".git").exists()
    shutil.rmtree(snapshot)
    save()


def sample(lane, flags, label):
    module = runtime / "module.wasm"
    shutil.copy2(images / (lane + ".wasm"), module)
    env = environment(runtime)
    env["MEMORY_CFG_BENCH_FLAGS"] = flags
    start = time.monotonic()
    result = subprocess.run(["bash", str(runner), "--invoke", "_start", str(module)],
                            cwd=runtime, env=env, capture_output=True, text=True, timeout=300)
    wall = time.monotonic() - start
    (work / (label + ".log")).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (label, result.stderr[-3000:])
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    assert len(lines) == 1 and lines[0].startswith("memory-check\t"), (label, lines)
    fields = lines[0].split("\t")
    assert len(fields) == 9 and fields[1] == flags, (label, fields)
    modules, repetitions, cold_us, cold_bytes, warm_us, warm_bytes = map(int, fields[2:8])
    assert (modules, repetitions) == (128, 128) and min(cold_us, warm_us, cold_bytes, warm_bytes) > 0
    # The guest rejects cold-with-no-checks and warm-with-rechecks. These are
    # region deltas; the cold setup and final rendering are outside the warm region.
    assert not (runtime / ".vibe/build/cache").exists()
    row = {"lane": lane, "flags": flags, "modules": modules, "warm_repetitions": repetitions,
           "cold_us": cold_us, "cold_bytes": cold_bytes, "warm_us": warm_us,
           "warm_bytes": warm_bytes, "environment_identity": fields[8], "wall_seconds": wall,
           "log": label + ".log"}
    print(json.dumps(row), flush=True)
    return row


for flags, tag in [("", "default"), ("alpha", "alpha")]:
    controls = [sample("a", flags, "aa-" + tag + "-" + str(i)) for i in range(2)]
    for field in ["cold_bytes", "warm_bytes", "environment_identity"]:
        assert controls[0][field] == controls[1][field], (flags, field, controls)
    receipt["aa_controls"].extend(controls)
    save()
    for round_no in range(3):
        for lane in ("a", "b") if round_no % 2 == 0 else ("b", "a"):
            row = sample(lane, flags, "ab-" + tag + "-" + str(round_no) + "-" + lane)
            row["round"] = round_no
            receipt["runs"].append(row)
            save()

identities = defaultdict(set)
for row in receipt["runs"]:
    identities[row["flags"]].add(row["environment_identity"])
assert all(len(values) == 1 for values in identities.values())
receipt["medians"] = {
    flags: {lane: {field: statistics.median(row[field] for row in receipt["runs"] if row["flags"] == flags and row["lane"] == lane)
                   for field in ["cold_us", "cold_bytes", "warm_us", "warm_bytes", "wall_seconds"]}
            for lane in ["a", "b"]}
    for flags in ["", "alpha"]
}
receipt["complete"] = True
save()
print(json.dumps(receipt["medians"]), flush=True)

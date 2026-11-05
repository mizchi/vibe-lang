"""Isolated A/B measurement of the migrated flat-source RC lane."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("root", type=Path)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--output", type=Path)
a = p.parse_args()
a.root = a.root.resolve()
a.baseline = a.baseline.resolve()
a.candidate = a.candidate.resolve()
out = a.output.resolve() if a.output else a.root / "_build/config-flat-perf"
out.mkdir(exist_ok=False)
for name, artifact in (("a", a.baseline), ("b", a.candidate)):
    shutil.copy2(artifact, out / (name + ".wasm"))
source = "lib/@vibe/compiler/_cli_adapter_module_source.vibe"
receipt = {"protocol": "Same candidate flat compiler source, explicit artifacts, AB/BA/AB, three fresh processes per artifact, VIBE_RC=1, FS_COMPILE=0, trusted source; isolated from other compiler/test jobs; startup included.",
           "source_sha256": hashlib.sha256((a.root / source).read_bytes()).hexdigest(),
           "artifacts": {name: hashlib.sha256((out / (name + ".wasm")).read_bytes()).hexdigest()
                         for name in ("a", "b")}, "runs": []}
env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
env.update(VIBE_RC="1", VIBE_FS_COMPILE="0", VIBE_INTERNAL_TRUSTED_SOURCE="1",
           VIBE_CFG="", VIBE_IMPORT_ABI="raw", VIBE_PREOPEN_DIR=str(a.root),
           VIBE_NODE_STACK_SIZE="131072", VIBE_MEM="1", VIBE_WASM_MEMORY_STATS="1")
for round_no in range(3):
    for name in (("a", "b") if round_no % 2 == 0 else ("b", "a")):
        output = out / ("out-" + name + ".wasm")
        output.unlink(missing_ok=True)
        start = time.monotonic()
        r = subprocess.run(["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
                            str(out / (name + ".wasm")), source, str(output), "cli_main"],
                           cwd=a.root, env=env, capture_output=True, text=True, timeout=900)
        wall = time.monotonic() - start
        log = out / f"{round_no}-{name}.log"
        log.write_text(r.stdout + r.stderr)
        assert r.returncode == 0 and r.stdout.strip() == "0" and output.exists(), str(log)
        memory = re.findall(r"vibe::mem heap_base=(\d+) heap_peak=(\d+) allocated=(\d+) committed=(\d+)", r.stderr)
        assert memory, str(log)
        base, peak, allocated, committed = map(int, memory[-1])
        row = {"round": round_no, "lane": name, "wall_seconds": wall, "heap_base": base,
               "heap_peak": peak, "allocated": allocated, "committed": committed,
               "output_bytes": output.stat().st_size,
               "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest()}
        receipt["runs"].append(row)
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(row), flush=True)
assert len({r["output_sha256"] for r in receipt["runs"]}) == 1
receipt["medians"] = {name: {metric: statistics.median(r[metric] for r in receipt["runs"] if r["lane"] == name)
                              for metric in ("allocated", "heap_peak", "wall_seconds")}
                      for name in ("a", "b")}
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt["medians"]), flush=True)

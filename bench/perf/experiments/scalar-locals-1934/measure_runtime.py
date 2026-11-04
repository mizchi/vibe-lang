"""ABBA application walltime through the production runner, including startup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("root", type=Path)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("--label", required=True)
p.add_argument("--iterations", type=int, default=50_000_000)
a = p.parse_args()
a.root = a.root.resolve()
out = a.root / "_build" / a.label
out.mkdir(parents=True, exist_ok=False)
source = Path(__file__).with_name("loop.vibe").read_text()
assert "i < 10000" in source
source = source.replace("i < 10000", f"i < {a.iterations}")
(out/"input.vibe").write_text(source)
env = dict(os.environ, VIBE_FS_COMPILE="1", VIBE_RC="0", VIBE_IMPORT_ABI="raw",
           VIBE_PREOPEN_DIR=str(a.root), VIBE_WASM_MEMORY_STATS="1")
expected_sum = a.iterations*a.iterations + 20*a.iterations
expected = {"a": f"{expected_sum} {24*a.iterations}", "b": f"{expected_sum} 0"}
receipt = {"iterations": a.iterations, "walltime_includes_runner_startup": True,
           "source_sha256": hashlib.sha256(source.encode()).hexdigest(), "apps": {}, "runs": []}
for lane, artifact in [("a", a.baseline), ("b", a.candidate)]:
    env["VIBE_BUILD_CACHE_DIR"] = str(out/f"cache-{lane}")
    app = out/f"{lane}.wasm"
    c = subprocess.run(["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
        str(artifact), str((out/"input.vibe").relative_to(a.root)), str(app), "main"],
        cwd=a.root, env=env, text=True, capture_output=True, timeout=900)
    assert c.returncode == 0 and c.stdout.strip() == "0" and app.exists(), (c.stdout, c.stderr)
    receipt["apps"][lane] = dict(bytes=app.stat().st_size, sha256=hashlib.sha256(app.read_bytes()).hexdigest())

def run(lane, measured):
    start = time.monotonic()
    r = subprocess.run(["bash", "scripts/run_wasm_vibe_host_runner.sh", str(out/f"{lane}.wasm")],
        cwd=a.root, env=env, text=True, capture_output=True, timeout=180)
    wall = time.monotonic()-start
    assert r.returncode == 0 and r.stdout.strip() == expected[lane], (lane, r.stdout, r.stderr)
    if measured:
        row = dict(lane=lane, wall_seconds=wall, stdout=r.stdout.strip(), memory_stats=r.stderr.strip())
        receipt["runs"].append(row)
        (out/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
        print(json.dumps(row), flush=True)

for lane in ("a", "b"):
    run(lane, False)
for round_no in range(4):
    for lane in (("a", "b") if round_no % 2 == 0 else ("b", "a")):
        run(lane, True)
receipt["medians"] = {lane: statistics.median(x["wall_seconds"] for x in receipt["runs"] if x["lane"]==lane)
                      for lane in ("a", "b")}
(out/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
print(json.dumps(receipt["medians"]), flush=True)

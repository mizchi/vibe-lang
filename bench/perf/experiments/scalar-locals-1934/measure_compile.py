"""Sequential equal-path cold/warm compiler comparison; explicit artifacts only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("root", type=Path)
p.add_argument("baseline", type=Path)
p.add_argument("candidate", type=Path)
p.add_argument("input")
p.add_argument("--rounds", type=int, default=3)
p.add_argument("--entry", default="cli_main")
p.add_argument("--label", default="measure-1934")
a = p.parse_args()
out = a.root / "_build" / a.label
out.mkdir(parents=True, exist_ok=True)
for lane, artifact in [("a", a.baseline), ("b", a.candidate)]:
    shutil.copy2(artifact, out / (lane + ".wasm"))
receipt = {"input": a.input, "root": str(a.root), "entry": a.entry,
           "artifacts": {lane: hashlib.sha256((out/(lane+".wasm")).read_bytes()).hexdigest()
                         for lane in ("a", "b")}, "runs": []}
env = os.environ.copy()
env.update(VIBE_INTERNAL_TRUSTED_SOURCE="1", VIBE_FS_COMPILE="1", VIBE_IMPORT_ABI="raw", VIBE_RC="0",
           VIBE_PREOPEN_DIR=str(a.root), VIBE_WASM_MEMORY_STATS="1")
for round_no in range(a.rounds):
    order = ("a", "b") if round_no % 2 == 0 else ("b", "a")
    for lane in order:
        cache = out / f"cache-{round_no}-{lane}"
        if cache.exists():
            raise RuntimeError(f"Refusing to reuse earlier measurement cache: {cache}")
        cache.mkdir()
        env["VIBE_BUILD_CACHE_DIR"] = str(cache)
        for temperature in ("cold", "warm"):
            output = out / f"out-{lane}.wasm"
            output.unlink(missing_ok=True)
            output.with_suffix(".wasm.diag").unlink(missing_ok=True)
            start = time.monotonic()
            proc = subprocess.run(["bash", "scripts/run_wasm_vibe_host_runner.sh",
                "--invoke", "cli_main", str(out/(lane+".wasm")),
                a.input, str(output), a.entry], cwd=a.root, env=env,
                capture_output=True, text=True, timeout=900)
            elapsed = time.monotonic() - start
            log = out / f"{round_no}-{lane}-{temperature}.log"
            log.write_text(proc.stdout + proc.stderr)
            if proc.returncode or proc.stdout.strip().splitlines()[-1:] != ["0"] or not output.exists():
                raise RuntimeError(f"Compile failed: {log}")
            heaps = re.findall(r"\[wasm-memory\].*?heap_ptr=(\d+)", proc.stderr)
            if not heaps:
                raise RuntimeError(f"Memory measurement missing: {log}")
            row = dict(round=round_no, lane=lane, temperature=temperature,
                       wall_seconds=elapsed, heap_ptr=int(heaps[-1]),
                       output_bytes=output.stat().st_size,
                       output_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
            receipt["runs"].append(row)
            (out/"receipt.json").write_text(json.dumps(receipt, indent=2)+"\n")
            print(json.dumps(row), flush=True)

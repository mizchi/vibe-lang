"""Compare real typed queries and host source reads with explicit compilers."""
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

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("output", type=Path, help="New directory under the checkout's _build")
args = parser.parse_args()
root = Path(__file__).resolve().parents[4]
work = args.output.resolve()
work.relative_to(root / "_build")
artifacts = {"a": args.baseline.resolve(), "b": args.candidate.resolve()}
assert all(path.is_file() for path in artifacts.values()), "Both compiler files are required"
work.mkdir(parents=True, exist_ok=False)
text = "//" + "x" * 1048576 + "\nfn count(xs: Array[Int]) -> Int { Array::length(xs) }\n"
source = work / "main.vibe"
source.write_text(text)
relative = str(source.relative_to(root))
active = work / "compiler.wasm"
output = work / "answer.json"
cache = work / "cache"
receipt = {
    "status": "running",
    "probe_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    "protocol": "Real typed grep; same literal source/compiler/cache/output paths; fresh Node processes, RC=0; three AB/BA/AB cold/warm pairs. Debug controls count actual host reads separately from timing.",
    "input": {"path": relative, "bytes": source.stat().st_size, "sha256": hashlib.sha256(source.read_bytes()).hexdigest()},
    "artifacts": {lane: hashlib.sha256(path.read_bytes()).hexdigest() for lane, path in artifacts.items()},
    "controls": {}, "runs": [],
}
expected = None


def invoke(debug, tag):
    global expected
    output.unlink(missing_ok=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith("VIBE_")}
    env.update(VIBE_GREP="1", VIBE_GREP_PATTERN="Array::length($(x:exp))", VIBE_GREP_WHERE="$x : Array[Int]\n",
               VIBE_GREP_JSON="1", VIBE_IMPORT_ABI="raw", VIBE_PREOPEN_DIR=str(root), VIBE_RC="0",
               VIBE_BUILD_CACHE_DIR=str(cache), VIBE_CHECKED_MODULE_CACHE="off",
               VIBE_DEBUG_FS="1" if debug else "0", VIBE_WASM_MEMORY_STATS="1")
    start = time.monotonic()
    result = subprocess.run(["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
                             str(active), relative, str(output)], cwd=root, env=env,
                            text=True, capture_output=True, timeout=120)
    wall = time.monotonic() - start
    (work / (tag + ".log")).write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and result.stdout.strip() == "0", tag
    answer = json.loads(output.read_text())
    assert len(answer) == 1, answer
    match = answer[0]
    offset = text.index("Array::length(xs)")
    assert match["path"] == relative and match["line"] == 2 and match["col"] == 35
    assert (match["start"], match["end"]) == (offset, offset + len("Array::length(xs)"))
    assert match["text"] == "Array::length(xs)" and not match["synthetic"]
    capture = match["captures"]["x"]
    assert capture["text"] == "xs" and capture["type"] == "Array[Int]" and not capture["synthetic"]
    assert (capture["start"], capture["end"]) == (offset + 14, offset + 16)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    if expected is None:
        expected = digest
    assert digest == expected, "Query answers differ"
    heaps = re.findall(r"heap_ptr=(\d+)", result.stderr)
    assert len(heaps) == 1, heaps
    return {"heap_ptr": int(heaps[0]), "wall_seconds": wall, "answer_sha256": digest,
            "root_reads": [line for line in result.stderr.splitlines() if line.startswith("[fs-read] " + relative + " bytes=")]}


try:
    for lane in ("a", "b"):
        cache.mkdir()
        shutil.copy2(artifacts[lane], active)
        control = invoke(True, lane + "-reads")
        receipt["controls"][lane] = control
        assert len(control["root_reads"]) == 2, f"{lane}: expected two entry reads, got {len(control['root_reads'])}"
        shutil.rmtree(cache)
    for number in range(3):
        for lane in ("a", "b") if number % 2 == 0 else ("b", "a"):
            cache.mkdir()
            shutil.copy2(artifacts[lane], active)
            for temperature in ("cold", "warm"):
                row = {"round": number, "lane": lane, "temperature": temperature, **invoke(False, f"{number}-{lane}-{temperature}")}
                row.pop("root_reads")
                receipt["runs"].append(row)
            shutil.rmtree(cache)
    receipt["medians"] = {temp: {lane: {metric: statistics.median(row[metric] for row in receipt["runs"] if row["lane"] == lane and row["temperature"] == temp) for metric in ("heap_ptr", "wall_seconds")} for lane in ("a", "b")} for temp in ("cold", "warm")}
    receipt["status"] = "pass"
finally:
    if receipt["status"] != "pass":
        receipt["status"] = "fail"
    shutil.rmtree(cache, ignore_errors=True)
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt["medians"], indent=2))

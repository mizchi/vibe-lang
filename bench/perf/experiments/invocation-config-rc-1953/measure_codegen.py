"""Measure checked RC-codegen regions on one candidate compiler."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("candidate_root", type=Path)
parser.add_argument("candidate_wasm", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--mode", choices=("rc", "rc-shadow"), required=True)
args = parser.parse_args()
root = args.candidate_root.resolve()
compiler = args.candidate_wasm.resolve()
work = args.output.resolve()
work.mkdir(exist_ok=False)
source = Path(__file__).with_name("checked_codegen.vibe")
image = root / "_build/rc-region.wasm"
relative_source = str(source.resolve().relative_to(root))
env = {key: value for key, value in os.environ.items() if not key.startswith("VIBE_")}
env.update(VIBE_FS_COMPILE="1", VIBE_RC="0", VIBE_IMPORT_ABI="raw", VIBE_PREOPEN_DIR=str(root), VIBE_BUILD_CACHE_DIR=str(work / "compile-cache"))
runner = root / "scripts/run_wasm_vibe_host_runner.sh"
compile_run = subprocess.run(["bash", str(runner), "--invoke", "cli_main", str(compiler), relative_source, str(image.relative_to(root)), "main"], cwd=root, env=env, capture_output=True, text=True, timeout=900)
(work / "compile.log").write_text(compile_run.stdout + compile_run.stderr)
assert compile_run.returncode == 0 and compile_run.stdout.strip() == "0" and image.is_file(), (compile_run.stdout, compile_run.stderr, Path(str(image) + ".diag").read_text() if Path(str(image) + ".diag").exists() else "")
subprocess.run(["wasm-tools", "validate", str(image)], check=True)
receipt = {"protocol": "Candidate only: 129 virtual modules whose 128 providers allocate integer arrays, checked before timing; one snapshot capture followed by priming both paths and measuring two steady full RC/RC-shadow compiles per fresh process. Both orders sampled three times. All 128 providers are called. Regional bump allocations exclude static heap. Compilation/validation/execution are serial. No full-compiler closure or speedup claim.", "mode": args.mode, "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(), "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(), "runs": []}
for round_no in range(3):
    for order in (("forward", "reverse") if round_no % 2 == 0 else ("reverse", "forward")):
        run_env = dict(env, OWNED_CODEGEN_ORDER=order, OWNED_CODEGEN_MODE=args.mode)
        start = time.monotonic()
        result = subprocess.run(["bash", str(runner), "--invoke", "_start", str(image)], cwd=root, env=run_env, capture_output=True, text=True, timeout=300)
        wall = time.monotonic() - start
        (work / f"{round_no}-{order}.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, (result.stdout, result.stderr)
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        assert len(lines) == 1 and lines[0].startswith("codegen-check\t"), lines
        fields = lines[0].split("\t")
        assert len(fields) == 8, fields
        names = ("capture_us", "capture_bytes", "compatibility_us", "compatibility_bytes", "owned_us", "owned_bytes")
        row = dict(zip(names, map(int, fields[1:7])), round=round_no, order=order, output_identity=fields[7], process_wall_seconds=wall)
        assert all(row[name] > 0 for name in names), row
        emitted = root / "_build/rc-region-output.wasm"
        subprocess.run(["wasm-tools", "validate", str(emitted)], check=True)
        child = subprocess.run(["wasmtime", "run", "-W", "exceptions=y", "--invoke", "main", str(emitted), "0"], capture_output=True, text=True, timeout=60)
        assert child.returncode == 0 and child.stdout.strip() == "8256", (child.stdout, child.stderr)
        row["output_sha256"] = hashlib.sha256(emitted.read_bytes()).hexdigest()
        row["runtime_output"] = child.stdout.strip()
        receipt["runs"].append(row)
        (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(row), flush=True)
assert len({row["output_sha256"] for row in receipt["runs"]}) == 1
receipt["medians"] = {name: statistics.median(row[name] for row in receipt["runs"]) for name in names}
(work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
shutil.rmtree(work / "compile-cache")
print(json.dumps(receipt["medians"]), flush=True)

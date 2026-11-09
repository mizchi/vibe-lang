"""Compare explicit named full compilers for the cfg-negation prerequisite using identical guest paths.

Run after building both artifacts, with no tests/builds active. Each artifact
compiles the same current source tree. Cold/warm pairs use a fresh cache and
fresh Node processes; compiler, cache and output paths are literally identical.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import time
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*args, **kwargs):
    return subprocess.run(*args, check=True, text=True, capture_output=True, **kwargs)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("baseline", type=Path)
parser.add_argument("candidate", type=Path)
parser.add_argument("output", type=Path, help="New, disposable directory under this checkout")
args = parser.parse_args()
root = Path.cwd().resolve()
assert (root / "scripts/run_wasm_vibe_host_runner.sh").is_file()
work = args.output.resolve()
assert root in work.parents and not work.exists()
work.mkdir(parents=True)
active_compiler = work / "compiler.wasm"
cache = work / "cache"
output = work / "output.wasm"
artifacts = {"baseline": args.baseline.resolve(), "candidate": args.candidate.resolve()}
receipt = {
    "protocol": "Same source and literal compiler/cache/output paths; fresh cache per cold/warm pair; fresh Node process each compile; three rounds in AB/BA/AB order; bump compiler, bump output; no concurrent builds/tests.",
    "base_commit": run(["git", "rev-parse", "HEAD"]).stdout.strip(),
    "machine": platform.platform(),
    "node": run(["node", "--version"]).stdout.strip(),
    "artifact_entry": "cli_main",
    "harness_sha256": sha(Path(__file__).resolve()),
    "artifacts": {},
    "runs": [],
    "source_sha256": {},
}
for name in run(["git", "diff", "HEAD", "--name-only"]).stdout.splitlines():
    path = root / name
    if path.is_file() and name.startswith(("lib/", "scripts/")):
        receipt["source_sha256"][name] = sha(path)
for name in ("lib/@vibe/compiler/_cli_adapter_module_source.vibe", "lib/@vibe/compiler/cache/codegen_fingerprint.vibe",
             "scripts/run_wasm_vibe_host_runner.sh", "scripts/wasm_vibe_host_runner.js"):
    receipt["source_sha256"][name] = sha(root / name)
for lane, artifact in artifacts.items():
    assert artifact.read_bytes()[:8] == b"\0asm\1\0\0\0"
    sizes = json.loads(run(["node", "scripts/wasm_func_sizes.mjs", str(artifact), "--json"]).stdout)
    assert sizes["namedFunctions"] == len(sizes["functions"])
    (work / (lane + "-functions.json")).write_text(json.dumps(sizes, indent=2) + "\n")
    families = {}
    for family, pattern in {
        "cfg_parser_helpers": r"^(cfg_|parse_cfg_)",
    }.items():
        rows = [f for f in sizes["functions"] if re.search(pattern, f["name"])]
        families[family] = {"functions": len(rows), "body_bytes": sum(f["size"] for f in rows), "rows": rows}
    receipt["artifacts"][lane] = {
        "sha256": sha(artifact), "file_bytes": artifact.stat().st_size,
        "code_section_payload_bytes": sizes["codeSectionBytes"],
        "function_body_bytes": sizes["codeBytes"],
        "functions": len(sizes["functions"]), "named_functions": sizes["namedFunctions"],
        "families": families,
    }
env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
env.update(
    VIBE_FS_COMPILE="1", VIBE_RC="0", VIBE_IMPORT_ABI="raw",
    VIBE_SKIP_RUN_INIT="1", VIBE_RUNNER_EXIT_WITH_RESULT="1",
    VIBE_PREOPEN_DIR=str(root), VIBE_BUILD_CACHE_DIR=str(cache),
    VIBE_WASM_MEMORY_STATS="1", VIBE_CHECKED_MODULE_CACHE="off",
    VIBE_EXPERIMENTAL_AST_CACHE="0", VIBE_EXPERIMENTAL_PERSISTENT_INGESTION_STAMP="0",
    VIBE_LINKED_OUTPUT_MEMO="off", VIBE_INTERNAL_TRUSTED_SOURCE="1",
)
receipt["compiler_environment"] = {k: v for k, v in env.items() if k.startswith("VIBE_")}
corpora = [("compiler", "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", "__no_entry__"),
           ("cli", "lib/@vibe/compiler/cli_adapter.vibe", "cli_main")]
for corpus, source, entry in corpora:
    receipt["source_sha256"][source] = sha(root / source)
    for round_no in range(3):
        order = ("baseline", "candidate") if round_no % 2 == 0 else ("candidate", "baseline")
        for lane in order:
            assert not cache.exists()
            cache.mkdir()
            shutil.copyfile(artifacts[lane], active_compiler)
            assert sha(active_compiler) == receipt["artifacts"][lane]["sha256"]
            for temperature in ("cold", "warm"):
                output.unlink(missing_ok=True)
                Path(str(output) + ".diag").unlink(missing_ok=True)
                start = time.monotonic()
                p = subprocess.run(
                    ["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
                     str(active_compiler), source, str(output), entry],
                    env=env, text=True, capture_output=True, timeout=900,
                )
                wall = time.monotonic() - start
                log = work / f"{corpus}-{round_no}-{lane}-{temperature}.log"
                log.write_text(p.stdout + p.stderr)
                assert p.returncode == 0 and p.stdout.strip() == "0" and output.is_file(), str(log)
                assert output.read_bytes()[:8] == b"\0asm\1\0\0\0", str(log)
                heaps = re.findall(r"\[wasm-memory\].*?heap_ptr=(\d+)", p.stderr)
                assert len(heaps) == 1, str(log)
                row = dict(corpus=corpus, round=round_no, lane=lane, temperature=temperature,
                           heap_ptr=int(heaps[0]), wall_seconds=wall,
                           output_bytes=output.stat().st_size, output_sha256=sha(output))
                receipt["runs"].append(row)
                print(json.dumps(row), flush=True)
                (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            shutil.copyfile(output, work / f"{corpus}-{lane}.wasm")
            assert sha(active_compiler) == receipt["artifacts"][lane]["sha256"]
            shutil.rmtree(cache)
for corpus, _, _ in corpora:
    rows = [r for r in receipt["runs"] if r["corpus"] == corpus]
    assert len(rows) == 12 and len({r["output_sha256"] for r in rows}) == 1, corpus
receipt["medians"] = {
    corpus: {temp: {lane: {
        metric: statistics.median(r[metric] for r in receipt["runs"]
                                  if (r["corpus"], r["temperature"], r["lane"]) == (corpus, temp, lane))
        for metric in ("wall_seconds", "heap_ptr")
    } for lane in artifacts} for temp in ("cold", "warm")} for corpus, _, _ in corpora
}
for name, expected in receipt["source_sha256"].items():
    assert sha(root / name) == expected, name
assert sha(Path(__file__).resolve()) == receipt["harness_sha256"]
receipt["status"] = "pass"
(work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt["medians"], indent=2), flush=True)

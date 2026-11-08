#!/usr/bin/env python3
"""Compare explicit compiler images using identical literal paths and inputs."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def uint(data, pos):
    value = shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, pos
        shift += 7
        assert shift < 35


def image(path):
    data = path.read_bytes()
    assert data[:8] == b"\0asm\1\0\0\0"
    result = {"bytes": len(data), "sha256": digest(path)}
    pos = 8
    while pos < len(data):
        section = data[pos]
        size, body = uint(data, pos + 1)
        assert body + size <= len(data)
        if section == 3:
            result["defined_functions"] = uint(data, body)[0]
        if section == 10:
            result["code_bytes"] = size
        pos = body + size
    return result


root = Path.cwd().resolve()
assert (root / "bootstrap/seed.json").is_file()
assert len(sys.argv) == 4, "usage: measure_micro.py BEFORE.wasm AFTER.wasm NEW_BUILD_DIR"
artifacts = dict(zip(("before", "after"), map(lambda p: Path(p).resolve(), sys.argv[1:3])))
hashes = {label: digest(path) for label, path in artifacts.items()}
assert all(path.read_bytes()[:8] == b"\0asm\1\0\0\0" for path in artifacts.values())
work = Path(sys.argv[3]).resolve()
assert work.is_relative_to(root / "_build") and work != root / "_build"
work.mkdir(exist_ok=False)
runner = root / "scripts/run_wasm_vibe_host_runner.sh"
guards = {str(p.relative_to(root)): digest(p) for p in (
    runner, root / "scripts/wasm_vibe_host_runner.js")}
source, compiler, output, cache = (work / n for n in ("entry.vibe", "compiler.wasm", "output.wasm", "cache"))
receipt = {
    "status": "running", "artifacts": hashes,
    "checkout_head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "staged_tree": subprocess.check_output(["git", "write-tree"], text=True).strip(),
    "measurement_script_sha256": digest(Path(__file__)),
    "runner_sha256": guards,
    "protocol": "Three alternating AB/BA/AB rounds, cold then warm in fresh Node processes; RC=0. Both images use the same literal compiler/source/cache/output paths. Source variants differ only by the local annotation. Compile wall time includes startup; runtime results are checked separately. This micro probe is not a whole-build speedup measurement.",
    "runtime_heap_scope": "Exported linear heap pointer, when available; excludes managed Wasm-GC objects and is not RSS or peak live memory.",
    "sources": {}, "rows": [],
}


def save():
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


try:
    for backend in ("linear", "gc"):
        for round_no in range(3):
            order = ("before", "after") if round_no % 2 == 0 else ("after", "before")
            annotations = (False, True) if round_no % 2 == 0 else (True, False)
            for annotated in annotations:
                text = "fn source() -> Int { 42 } export fn answer() -> Int { let x" + (": Int" if annotated else "") + " = source(); x }\n"
                source.write_text(text)
                receipt["sources"][str(annotated)] = {"text": text, "sha256": digest(source)}
                for label in order:
                    shutil.copyfile(artifacts[label], compiler)
                    assert digest(compiler) == hashes[label]
                    cache.mkdir()
                    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
                    env.update(VIBE_PREOPEN_DIR=str(root), VIBE_FS_COMPILE="1", VIBE_IMPORT_ABI="raw", VIBE_BACKEND=backend, VIBE_RC="0", VIBE_BUILD_CACHE_DIR=str(cache), VIBE_WASM_MEMORY_STATS="1")
                    for temperature in ("cold", "warm"):
                        output.unlink(missing_ok=True)
                        started = time.monotonic()
                        compile_run = subprocess.run(["bash", str(runner), "--invoke", "cli_main", str(compiler), str(source), str(output), "answer"], env=env, text=True, capture_output=True, timeout=120)
                        wall = time.monotonic() - started
                        prefix = f"{backend}-{round_no}-{annotated}-{label}-{temperature}"
                        (work / (prefix + ".log")).write_text(compile_run.stdout + compile_run.stderr)
                        assert compile_run.returncode == 0, compile_run.stderr
                        heap = re.search(r"heap_ptr=(\d+)", compile_run.stderr)
                        assert heap, "missing compiler heap counter"
                        run_env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
                        run_env.update(VIBE_PREOPEN_DIR=str(root), VIBE_WASM_MEMORY_STATS="1")
                        run = subprocess.run(["bash", str(runner), "--invoke", "_start", str(output)], env=run_env, text=True, capture_output=True, timeout=30)
                        (work / (prefix + ".run.log")).write_text(run.stdout + run.stderr)
                        assert run.returncode == 0 and run.stdout.strip() == "42", (run.stdout, run.stderr)
                        runtime_heap = re.search(r"heap_ptr=(\d+)", run.stderr)
                        row = {"backend": backend, "round": round_no, "annotated": annotated, "variant": label, "temperature": temperature, "wall_seconds": wall, "compiler_heap_ptr": int(heap[1]), "runtime_linear_heap_ptr": int(runtime_heap[1]) if runtime_heap else None, "answer": "42", "image": image(output)}
                        receipt["rows"].append(row)
                        save()
                        print(json.dumps(row), flush=True)
                    shutil.rmtree(cache)
    images = {}
    for backend in ("linear", "gc"):
        for label in ("before", "after"):
            groups = {}
            for annotated in (False, True):
                rows = [r for r in receipt["rows"] if r["backend"] == backend and r["variant"] == label and r["annotated"] == annotated]
                assert len(rows) == 6 and len({r["image"]["sha256"] for r in rows}) == 1
                groups[annotated] = rows[0]["image"]
            if backend == "gc" and label == "before":
                assert groups[True]["defined_functions"] == groups[False]["defined_functions"] + 1
                assert groups[True]["bytes"] > groups[False]["bytes"]
            else:
                assert groups[False] == groups[True], (backend, label, groups)
            images[backend, label] = groups
    assert images["linear", "before"] == images["linear", "after"]
    assert images["gc", "before"][False] == images["gc", "after"][False]
    assert hashes == {label: digest(path) for label, path in artifacts.items()}
    assert guards == {p: digest(root / p) for p in guards}
    assert receipt["staged_tree"] == subprocess.check_output(["git", "write-tree"], text=True).strip()
    subprocess.run(["git", "diff", "--exit-code"], check=True)
    receipt["status"] = "pass"
except BaseException as exc:
    receipt.update(status="fail", error=str(exc))
    raise
finally:
    if cache.exists():
        shutil.rmtree(cache)
    save()

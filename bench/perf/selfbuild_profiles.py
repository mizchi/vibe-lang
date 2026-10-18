#!/usr/bin/env python3
"""Separate diagnostic runs for selfbuild_baseline.py; never promotion walltime.

Run only after bootstrap, images and matrix have completed, on an idle host.
The named compiler must differ only by custom name sections. Parent and worker
profiles use the same image receipts as the measured matrix. Captured worker
inputs and every profiled product are checked against successful real builds.
"""
import argparse
import collections
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import selfbuild_baseline as base


def without_names(data):
    if data[:8] != b"\0asm\x01\0\0\0":
        raise ValueError("expected core Wasm")
    pos = 8
    output = bytearray(data[:8])
    def varint():
        nonlocal pos
        value = shift = 0
        while True:
            byte = data[pos]
            pos += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
            shift += 7
            if shift > 35:
                raise ValueError("invalid Wasm length")
    while pos < len(data):
        start = pos
        kind = data[pos]
        pos += 1
        length = varint()
        end = pos + length
        if end > len(data):
            raise ValueError("truncated Wasm section")
        name = None
        if kind == 0:
            count = varint()
            name = data[pos:pos + count]
        if name != b"name":
            output.extend(data[start:end])
        pos = end
    return bytes(output)


def run(command, cwd, env, directory):
    directory.mkdir()
    with (directory / "stdout.log").open("w") as out, (directory / "stderr.log").open("w") as err:
        subprocess.run(command, cwd=cwd, env=env, stdout=out, stderr=err, check=True, timeout=600)


def named(workspace):
    corpus = workspace / "corpus"
    generation = corpus / "_build/measured-generation"
    receipt = base.fixed_point(generation)
    env = base.clean_env(corpus) | {"VIBE_WASM_NAMES": "1", "VIBE_PREBUILT_MODULE_SOURCE": str(generation / "cli_adapter_module_source.vibe"),
           "VIBE_PREBUILT_MODULE_SOURCE_SHA256": base.sha(generation / "cli_adapter_module_source.vibe"),
           "VIBE_BUILD_CACHE_DIR": str(workspace / "profile-build-cache")}
    target = workspace / "named"
    run(["bash", "scripts/generations.sh", "build", "--stage3", "--out-dir", str(target)], corpus, env, workspace / "named-build")
    base.fixed_point(target)
    original = (generation / "stage2.wasm").read_bytes()
    profiled = (target / "stage2.wasm").read_bytes()
    if profiled == original or without_names(profiled) != without_names(original):
        raise ValueError("named compiler is absent or differs in executable sections")
    base.write(workspace / "named-receipt.json", {"ordinary_generation": receipt,
               "ordinary_sha256": base.sha(generation / "stage2.wasm"), "named_sha256": base.sha(target / "stage2.wasm"),
               "only_name_sections_differ": True})


def ordinary(workspace):
    corpus = workspace / "corpus"
    out = workspace / "ordinary-profiles"
    out.mkdir()
    compiler = workspace / "named/stage2.wasm"
    recorded = json.loads((workspace / "named-receipt.json").read_text())
    if base.sha(compiler) != recorded["named_sha256"]:
        raise ValueError("named compiler changed")
    for subject, source, entry, fs, rc in [
        ("actual-flat-selfcompile", "_build/measured-generation/cli_adapter_module_source.vibe", "cli_main", "0", "0"),
        ("split-cli-fs", "lib/@vibe/cli/entry.vibe", "cli_main", "1", "1")]:
        hashes = []
        for index in range(4):
            private = out / f"{subject}-{index}"
            env = base.clean_env(corpus) | {"VIBE_RC": rc, "VIBE_FS_COMPILE": fs, "VIBE_MEM": "1",
                   "VIBE_INTERNAL_TRUSTED_SOURCE": "1", "VIBE_BUILD_CACHE_DIR": str(out / f"{subject}-cache")}
            if fs == "0":
                env["VIBE_NODE_WASM_FLAGS"] = "--experimental-wasm-exnref --stack-size=131072"
            if index:
                env["VIBE_NODE_EXTRA_FLAGS"] = "\n".join(["--cpu-prof", f"--cpu-prof-dir={private}", "--cpu-prof-name=cpu.cpuprofile"])
            run(["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main", str(compiler),
                 source, str(private / "out.wasm"), entry], corpus, env, private)
            hashes.append(base.sha(private / "out.wasm"))
            print(subject, index, "profile" if index else "warmup", flush=True)
        if len(set(hashes)) != 1:
            raise ValueError("profiled output differs from unprofiled reference")
        if fs == "0" and hashes[0] != recorded["ordinary_sha256"]:
            raise ValueError("flat profile is not the measured selfcompile")
        base.write(out / f"{subject}-receipt.json", {"output_sha256": hashes[0], "profiled_runs": 3, "walltime_use": "diagnostic only"})


CAPTURE = '''#!/usr/bin/env python3
import os, sys, json, subprocess, shutil, hashlib
from pathlib import Path
code = subprocess.call([os.environ['SELFBUILD_NATIVE_RUNNER'], *sys.argv[1:]])
if code == 0 and os.environ.get('VIBE_LOWERING_WORKERS'):
    path = Path(os.environ['VIBE_LOWERING_WORKERS'])
    plan = json.loads(path.read_text())
    target = Path(os.environ['SELFBUILD_CAPTURE']) / path.stem
    target.mkdir(parents=True)
    shutil.copy2(plan['context'], target / 'shared.context')
    queues = []
    for queue in plan['queues']:
        rows = []
        for name in queue:
            job = Path(name)
            product = Path(name + '.product')
            shutil.copy2(job, target / job.name)
            rows.append({'name': job.name, 'input_bytes': job.stat().st_size,
                         'product_bytes': product.stat().st_size,
                         'product_sha256': hashlib.sha256(product.read_bytes()).hexdigest()})
        queues.append(rows)
    (target / 'capture.json').write_text(json.dumps({'queues': queues,
        'context_bytes': (target / 'shared.context').stat().st_size}, indent=2) + '\\n')
sys.exit(code)
'''


def parents(workspace):
    corpus = workspace / "corpus"
    images = workspace / "engines/images"
    runner = workspace / "engines/o0/viberun"
    base.image_receipts(workspace)
    matrix = json.loads((workspace / "matrix/measurement.json").read_text())
    if not matrix.get("verified_complete"):
        raise ValueError("complete the unprofiled matrix before diagnostics")
    out = workspace / "parent-profiles"
    out.mkdir()
    wrapper = out / "capture-runner.py"
    wrapper.write_text(CAPTURE)
    wrapper.chmod(0o755)
    for subject, source, entry in [("compiler", "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", "__no_entry__"),
                                   ("split-cli", "lib/@vibe/cli/entry.vibe", "cli_main")]:
        for index in range(4):
            private = out / f"{subject}-{index}"
            private.mkdir()
            config = private / "service.json"
            base.write(config, {"version": 1, "worker": str(images / "worker.wasm"),
                       "coordinator": str(images / "coordinator.component.wasm"), "runner": str(wrapper if index == 0 else runner),
                       "cwd": str(corpus), "directory": str(private), "jobs": 4})
            env = base.clean_env(corpus) | {"VIBE_RC": "1", "VIBE_MEM": "1", "VIBE_BUILD_CACHE_DIR": str(out / f"{subject}-cache"),
                   "VIBE_NATIVE_CACHE_DIR": str(workspace / "native-cache"), "VIBE_LOWERING_INPUT": source,
                   "VIBE_LOWERING_OUTPUT": str(private / "out.wasm"), "VIBE_LOWERING_ENTRY": entry,
                   "VIBE_LOWERING_DIRECTORY": str(private),
                   "VIBE_LOWERING_MODE": "single", "VIBE_FUNCTION_JOBS": "4", "VIBE_LOWERING_SERVICE_CONFIG": str(config),
                   "SELFBUILD_NATIVE_RUNNER": str(runner), "SELFBUILD_CAPTURE": str(out / f"capture-{subject}")}
            if index:
                env["VIBE_GUEST_PROFILE"] = str(private / "cpu.json")
            run([str(runner), str(images / "compile.wasm")], corpus, env, private / "logs")
            if base.sha(private / "out.wasm") != matrix["artifacts"][subject]:
                raise ValueError("parent diagnostic differs from measured frontend output")
            print(subject, index, "parent profile" if index else "input capture", flush=True)


def workers(workspace):
    corpus = workspace / "corpus"
    out = workspace / "worker-profiles"
    out.mkdir()
    base.image_receipts(workspace)
    for capture in sorted((workspace / "parent-profiles").glob("capture-*/*/capture.json")):
        record = json.loads(capture.read_text())
        family = capture.parent.parent.name
        for slot, queue in enumerate(record["queues"]):
            if not queue:
                continue
            private = out / f"{family}-{capture.parent.name}-{slot}"
            private.mkdir()
            listing = private / "jobs.list"
            listing.write_text("\n".join(str(capture.parent / row["name"]) for row in queue))
            for index in range(4):
                env = base.clean_env(corpus) | {"VIBE_RC": "1", "VIBE_MEM": "1", "VIBE_NATIVE_CACHE_DIR": str(workspace / "native-cache"),
                       "VIBE_LOWERING_WORKER_LIST": str(listing), "VIBE_LOWERING_SHARED_CONTEXT": str(capture.parent / "shared.context")}
                if index:
                    env["VIBE_GUEST_PROFILE"] = str(private / f"cpu-{index}.json")
                run([str(workspace / "engines/o0/viberun"), str(workspace / "engines/images/worker.wasm")], corpus, env, private / str(index))
                for row in queue:
                    if base.sha(capture.parent / (row["name"] + ".product")) != row["product_sha256"]:
                        raise ValueError("worker replay differs from captured real build product")
                print(family, slot, index, "worker profile" if index else "unprofiled memory control", flush=True)


def startup(workspace):
    """Net native-code cache cost on a fixed small source, outside the matrix."""
    corpus = workspace / "corpus"
    base.image_receipts(workspace)
    out = workspace / "startup"
    out.mkdir()
    rows = []
    expected = None
    for rnd in range(3):
        for variant in (["o0", "s0", "p1"] if rnd % 2 == 0 else ["p1", "s0", "o0"]):
            private = out / f"{rnd}-{variant}"
            private.mkdir()
            for temperature in ["cold", "warm"]:
                # Each run has an EMPTY guest cache; only native code is reused.
                destination = private / f"{temperature}.wasm"
                command, env = base.matrix_command(workspace, variant, "perf-smoke.vibe", destination,
                               "main", private / f"{temperature}-guest", private / f"{temperature}.json")
                env["VIBE_NATIVE_CACHE_DIR"] = str(private / "native")
                result = base.measure(command, corpus, env, private / temperature)
                digest = base.sha(destination)
                if expected is None:
                    expected = digest
                if digest != expected:
                    raise ValueError("startup control output differs across routes")
                result.update(round=rnd, variant=variant, native_cache=temperature, guest_cache="cold", artifact_sha256=digest)
                rows.append(result)
                base.write(out / "measurement.json", {"samples": rows,
                    "interpretation": "Complete small-input startup with native cache cold/warm and guest cache cold in both. The difference is net JIT/cache benefit, not isolated engine-instantiation time or a large-build speedup."})
                print("startup", rnd, variant, temperature, round(result["wall_s"], 3), flush=True)
    base.write(out / "receipt.json", {"verified_complete": True, "samples": len(rows), "artifact_sha256": expected})


def validation(workspace):
    """Test whether the seed validation can produce the stage1 artifact."""
    corpus = workspace / "corpus"
    generation = corpus / "_build/measured-generation"
    receipt = base.fixed_point(generation)
    source = generation / "cli_adapter_module_source.vibe"
    copied = corpus / "_build/validation_probe_source.vibe"
    shutil.copy2(source, copied)
    if base.sha(source) != base.sha(copied):
        raise ValueError("validation probe source differs")
    out = workspace / "validation-probe"
    out.mkdir()
    env = base.clean_env(corpus) | {"VIBE_RC": "0", "VIBE_FS_COMPILE": "0", "VIBE_MEM": "1",
        "VIBE_INTERNAL_TRUSTED_SOURCE": "1", "VIBE_BUILD_CACHE_DIR": str(workspace / "validation-cache"),
        "VIBE_NODE_WASM_FLAGS": "--experimental-wasm-exnref --stack-size=131072"}
    portable = list((corpus / "_build/selfhost/generations").glob("*/generation.json"))
    if len(portable) != 1:
        raise ValueError("expected one portable CLI producer")
    portable_receipt = json.loads(portable[0].read_text())
    if base.sha(portable[0].parent / "cli_adapter_module_source.vibe") != base.sha(source):
        raise ValueError("compiler and portable CLI flat inputs differ")
    records = []
    for entry, expected in [("cli_main", receipt["stages"]["stage1"]["sha256"]),
                            ("main", portable_receipt["stages"]["stage1"]["sha256"])]:
        output = corpus / f"_build/validation_probe_{entry}.wasm"
        output.unlink(missing_ok=True)
        output.with_suffix(".wasm.diag").unlink(missing_ok=True)
        run(["bash", "scripts/run_wasm_vibe_host_runner.sh", "--invoke", "cli_main",
             "bootstrap/seed/compiler.wasm", str(copied.relative_to(corpus)), str(output.relative_to(corpus)), entry], corpus, env, out / entry)
        actual = base.sha(output)
        if actual != expected:
            raise ValueError("validation probe differs from measured stage1 for entry " + entry)
        records.append({"entry": entry, "validation_output_sha256": actual,
                        "measured_stage1_sha256": expected, "stage1_byte_identity": actual == expected,
                        "requires_entry_plumbing": entry != "cli_main"})
        print("validation", entry, "output matches measured stage1:", actual == expected, flush=True)
    base.write(out / "receipt.json", {"input_sha256": base.sha(source), "seed_sha256": base.sha(corpus / "bootstrap/seed/compiler.wasm"),
        "entries": records, "current_validator_entry": "cli_main",
        "scope": "Diagnostic seed compiles of copied flat input. Portable CLI requires main-entry validation before reuse. A match supports investigating receipt-bound reuse; it does not implement or prove freshness/publication safety."})


def context_pool(data):
    """Read the shared v3/v4/v6 string-pool prefix; never expose literal text."""
    position = 0
    def integer():
        nonlocal position
        result = shift = 0
        while True:
            if position >= len(data) or shift > 63:
                raise ValueError("truncated context prefix")
            byte = data[position]
            position += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result
            shift += 7
    def string():
        nonlocal position
        length = integer()
        if length > len(data) - position:
            raise ValueError("truncated context string")
        result = data[position:position + length]
        position += length
        return result
    formats = {b"vibe-function-context-3": 3, b"vibe-function-context-4": 4, b"vibe-function-context-6": 6}
    version = formats.get(string())
    if version is None:
        raise ValueError("unsupported context prefix")
    start = position
    count = integer()
    if count > len(data):
        raise ValueError("impossible context string count")
    lengths = []
    for index in range(count):
        value = string()
        lengths.append({"index": index, "bytes": len(value), "sha256": hashlib.sha256(value).hexdigest()})
    return {"context_format": version, "context_bytes": len(data), "pool_entries": count, "pool_wire_bytes": position - start,
            "pool_payload_bytes": sum(row["bytes"] for row in lengths),
            "largest_literals": sorted(lengths, key=lambda row: row["bytes"], reverse=True)[:10]}


def memory(workspace):
    result = {"contexts": {}, "parent_guest": {}, "worker_guest": {},
              "scope": "Context prefix is a wire-size breakdown. Parent and worker counters are diagnostic controls; guest bump frontier, reserved pages and allocation volume are separate from simultaneous matrix RSS. Do not sum independent per-process peaks."}
    for path in sorted((workspace / "parent-profiles").glob("capture-*/*/shared.context")):
        result["contexts"][str(path.relative_to(workspace))] = context_pool(path.read_bytes())
    for path in sorted((workspace / "parent-profiles").glob("*/logs/stderr.log")):
        result["parent_guest"][str(path.relative_to(workspace))] = base.guest_memory(path.read_text())
    for path in sorted((workspace / "worker-profiles").glob("*/0/stderr.log")):
        result["worker_guest"][str(path.relative_to(workspace))] = base.guest_memory(path.read_text())
    if not all(result[key] for key in ["contexts", "parent_guest", "worker_guest"]):
        raise ValueError("memory diagnostics are incomplete")
    base.write(workspace / "memory-summary.json", result)


def summarize(workspace):
    result = {}
    paths = [path for directory in workspace.glob("*-profiles") for path in directory.rglob("*") if path.is_file()]
    for path in sorted(paths):
        if not (path.name.startswith("cpu") or path.suffix == ".cpuprofile"):
            continue
        profile = json.loads(path.read_text())
        self_weights = collections.Counter()
        inclusive = collections.Counter()
        if "nodes" in profile:
            nodes = {node["id"]: node for node in profile["nodes"]}
            parents = {child: node["id"] for node in profile["nodes"] for child in node.get("children", [])}
            for sample, weight in zip(profile["samples"], profile["timeDeltas"]):
                self_weights[nodes[sample]["callFrame"]["functionName"]] += weight
                seen = set()
                while sample is not None:
                    seen.add(nodes[sample]["callFrame"]["functionName"])
                    sample = parents.get(sample)
                inclusive.update({name: weight for name in seen})
            unit = "sampled microseconds; startup/host/idle included"
        else:
            for thread in profile["threads"]:
                table = thread["stackTable"]
                frames = thread["frameTable"]
                functions = thread["funcTable"]
                names = thread["stringArray"]
                def function(stack):
                    return names[functions["name"][frames["func"][table["frame"][stack]]]]
                for stack in thread["samples"]["stack"]:
                    if stack is None:
                        continue
                    self_weights[function(stack)] += 1
                    seen = set()
                    while stack is not None:
                        seen.add(function(stack))
                        stack = table["prefix"][stack]
                    inclusive.update(seen)
            unit = "guest epoch samples; host work excluded"
        total = sum(self_weights.values())
        if total <= 0:
            raise ValueError("empty CPU profile: " + str(path))
        result[str(path.relative_to(workspace))] = {"unit": unit, "total_weight": total,
            "self": [{"name": n, "weight": w, "percent": 100 * w / total} for n, w in self_weights.most_common(35)],
            "inclusive": [{"name": n, "weight": w, "percent": 100 * w / total} for n, w in inclusive.most_common(100)],
            "profile_sha256": base.sha(path), "interpretation": "Inclusive ancestors overlap; never sum them or treat these diagnostic walltimes as performance wins."}
    if not result:
        raise ValueError("no CPU profiles found")
    base.write(workspace / "profile-summary.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["named", "ordinary", "parents", "workers", "startup", "validation", "memory", "summarize"])
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    meta = json.loads((workspace / "workspace.json").read_text())
    base.verify_source(workspace / "corpus", meta)
    globals()[args.command](workspace)
    base.verify_source(workspace / "corpus", meta)


if __name__ == "__main__":
    main()

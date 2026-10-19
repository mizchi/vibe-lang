"""Exercise real CLI CPU workers, byte parity, execution and atomic refusals."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def assert_context_receipt_format(artifacts, runner, env, project, label, expected):
    """Observe a real producer's envelope independently of receipt metadata."""
    private = project / label
    private.mkdir()
    observed = private / "context-magic.txt"
    wrapper = private / "capture-runner.py"
    wrapper.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
code = subprocess.call([os.environ["FUNCTION_PROTOCOL_REAL_RUNNER"], *sys.argv[1:]])
if code == 0 and os.environ.get("VIBE_LOWERING_WORKERS"):
    plan = json.loads(Path(os.environ["VIBE_LOWERING_WORKERS"]).read_text())
    with Path(plan["context"]).open("rb") as stream:
        size = stream.read(1)
        assert len(size) == 1 and 0 < size[0] < 128
        magic = stream.read(size[0])
        assert len(magic) == size[0]
    Path(os.environ["FUNCTION_PROTOCOL_MAGIC_OUT"]).write_text(magic.decode("ascii"))
sys.exit(code)
''')
    wrapper.chmod(0o755)
    config = private / "service.json"
    config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
        "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(wrapper),
        "cwd": str(project), "directory": str(private), "jobs": 2}))
    output = private / "out.wasm"
    selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_OUTPUT=str(output),
        VIBE_BUILD_CACHE_DIR=str(private / "cache"),
        VIBE_LOWERING_ENTRY="main", VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
        VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
        FUNCTION_PROTOCOL_REAL_RUNNER=str(runner), FUNCTION_PROTOCOL_MAGIC_OUT=str(observed))
    result = subprocess.run([str(runner), "--function-phases", str(artifacts / "compile.wasm")], cwd=project,
                            env=selected, capture_output=True, text=True, timeout=180)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert output.read_bytes() == expected.read_bytes(), "protocol probe output differs"
    receipt = json.loads((artifacts / "build.json").read_text())
    assert observed.read_text() == f"vibe-function-context-{receipt['context_format']}", "context wire/receipt mismatch"


def assert_packet_integrity(repo, artifacts, runner, env, project):
    """Mutate real packets and verify context refusal precedes product reads."""
    root = project / "packet-integrity"
    root.mkdir()
    names = [f"receipt_worker_function_{i}" for i in range(96)]
    functions = [f"fn {names[0]}(n: Int) -> Int {{ n + 1 }}"]
    functions += [f"fn {name}(n: Int) -> Int {{ {names[i - 1]}(n) + 1 }}"
                  for i, name in enumerate(names) if i]
    (root / "main.vibe").write_text("\n".join(functions)
                                    + f"\nfn main() -> Int {{ {names[-1]}(1) }}\n")
    ordinary = root / "ordinary.wasm"
    subprocess.run(["bash", str(repo / "runtime/vibe"), "build", "main.vibe", "-o", str(ordinary)],
                   cwd=root, env=dict(env, VIBE_BUILD_CACHE_DIR=str(root / "ordinary-cache")),
                   capture_output=True, text=True, check=True, timeout=180)
    wrapper = root / "tamper-runner.py"
    wrapper.write_text('''#!/usr/bin/env python3
import hashlib, json, os, subprocess, sys
from pathlib import Path
plan_path = os.environ.get("VIBE_LOWERING_WORKERS")
kind = os.environ["FUNCTION_PACKET_KIND"]
def mutate():
    plan = json.loads(Path(plan_path).read_text())
    job = next(Path(p) for queue in plan["queues"] for p in queue)
    path = (Path(plan["context"]) if kind.startswith("context") else
            Path(str(job) + ".product") if kind == "product" else job)
    data = path.read_bytes()
    assert len(data) >= 1024, "packet must include the old unread byte range"
    before = hashlib.sha256(data).hexdigest()
    changed = bytearray(data)
    offset = len(data) * 3 // 4
    if offset % 1024 >= 960:
        offset -= 64
    # Old bump compression read the lower half plus each chunk's last block.
    assert offset > len(data) // 2 + 64
    assert offset % 1024 < 960 and offset < (len(data) - 1) // 64 * 64
    if kind == "context-short":
        del changed[-1]
    elif kind == "context-extra":
        changed.append(0)
    else:
        changed[offset] ^= 1
    path.write_bytes(changed)
    if kind.startswith("context"):
        # If the host starts reading products before checking the context,
        # the missing product diagnostic replaces the required context refusal.
        Path(str(job) + ".product").unlink()
    after = hashlib.sha256(path.read_bytes()).hexdigest()
    assert before != after
    Path(os.environ["FUNCTION_PACKET_RECORD"]).write_text(json.dumps({
        "kind": kind, "offset": offset, "length": len(data), "changed_length": len(changed),
        "before": before, "after": after}))
if plan_path and kind == "job":
    mutate()
code = subprocess.call([os.environ["FUNCTION_PACKET_RUNNER"], *sys.argv[1:]])
if code == 0 and plan_path and (kind == "product" or kind.startswith("context")):
    mutate()
sys.exit(code)
''')
    wrapper.chmod(0o755)
    for kind in ("control", "job", "product", "context", "context-short", "context-extra"):
        private = root / kind
        private.mkdir()
        output = private / "out.wasm"
        output.write_bytes(b"previous build")
        config = private / "service.json"
        config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
            "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(wrapper),
            "cwd": str(root), "directory": str(private), "jobs": 2}))
        record = private / "changed.json"
        selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_OUTPUT=str(output),
            VIBE_BUILD_CACHE_DIR=str(private / "cache"), VIBE_LOWERING_ENTRY="main",
            VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
            VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
            FUNCTION_PACKET_RUNNER=str(runner), FUNCTION_PACKET_KIND=kind,
            FUNCTION_PACKET_RECORD=str(record))
        result = subprocess.run([str(runner), "--function-phases", str(artifacts / "compile.wasm")], cwd=root,
                                env=selected, capture_output=True, text=True, timeout=180)
        if kind == "control":
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert output.read_bytes() == ordinary.read_bytes(), "packet control differs"
        else:
            changed = json.loads(record.read_text())
            assert changed["kind"] == kind and changed["offset"] > changed["length"] // 2 + 64
            assert changed["offset"] % 1024 < 960
            assert changed["offset"] < (changed["length"] - 1) // 64 * 64
            assert changed["before"] != changed["after"] and changed["length"] >= 1024
            assert result.returncode != 0 and output.read_bytes() == b"previous build", result
            if kind.startswith("context"):
                delta = {"context": 0, "context-short": -1, "context-extra": 1}[kind]
                assert changed["changed_length"] == changed["length"] + delta
                assert "shared context changed after preparation" in result.stderr, result
            elif kind == "product":
                assert "functions: product receipt differs" in result.stderr, result
            else:
                assert any(s in result.stderr for s in
                           ("coordinator exited", "functions: product receipt differs", "phase input changed after preparation:")), result
    print("changed jobs/products and changed/short/extra context preserve previous output", flush=True)



def assert_finisher_recompile_refused(repo, compiler, artifacts, runner, env, project):
    """A real compiled serial-finalizer mutant must fail at the FS boundary."""
    private = project / "finisher-recompile"
    private.mkdir()
    target = repo / "lib/@vibe/function_build/phases/entry.vibe"
    source = target.read_text()
    before = "finish_function_assembly(assembly, merged)"
    after = 'compile_file_fs_mode_rc_body_cached(Env::get("VIBE_LOWERING_INPUT"), Env::get("VIBE_LOWERING_ENTRY"), "off")'
    assert source.count(before) == 1
    overlay = private / "serial-finisher.vibe"
    overlay.write_text(source.replace(before, after))
    image = private / "compile.wasm"
    compile_env = dict(env, VIBE_RC="0", VIBE_FS_COMPILE="1", VIBE_WASM_NAMES="1",
        VIBE_WASM_KEEP_EXPORTS="1", VIBE_SOURCE_OVERLAY=str(target),
        VIBE_SOURCE_OVERLAY_WITH=str(overlay), VIBE_BUILD_CACHE_DIR=str(private / "compile-cache"))
    result = subprocess.run([str(runner), str(compiler), str(target), str(image), "__no_entry__"],
        cwd=repo, env=compile_env, capture_output=True, text=True, timeout=180)
    assert result.returncode == 0 and image.is_file() and image.stat().st_size > 0, result
    assert image.read_bytes() != (artifacts / "compile.wasm").read_bytes(), "mutant did not change image"
    config = private / "service.json"
    config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
        "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(runner),
        "cwd": str(project), "directory": str(private), "jobs": 2}))
    output = private / "previous.wasm"
    output.write_bytes(b"previous build")
    selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_ENTRY="main",
        VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
        VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
        VIBE_LOWERING_OUTPUT=str(output), VIBE_BUILD_CACHE_DIR=str(private / "run-cache"))
    result = subprocess.run([str(runner), "--function-phases", str(image)], cwd=project,
        env=selected, capture_output=True, text=True, timeout=180)
    assert result.returncode != 0 and output.read_bytes() == b"previous build", result
    assert "function finisher cannot use source or output capability" in result.stderr or "function finisher may only read" in result.stderr, result
    print("compiled serial-finalizer mutant is refused before source reads/publication", flush=True)


def assert_original_phase_receipt_bound(repo, compiler, artifacts, runner, env, project, expected):
    """A valid rewritten packet needs its original returned digest, not a file."""
    target = repo / "lib/@vibe/function_build/phases/entry.vibe"
    source = target.read_text()
    marker = '  Fs::write_bytes(directory + "/function.assembly", packet)\n'
    assert source.count(marker) == 1
    rewrite = '''  Array::push(assembly.replay.guard_layout, 9)
  let changed_packet = write_function_assembly(assembly, context_digest)
  Fs::write_bytes(directory + "/function.assembly", changed_packet)
'''
    for bound in (True, False):
        private = project / ("receipt-bound" if bound else "receipt-stale")
        private.mkdir()
        changed = source.replace(marker, marker + rewrite)
        if bound:
            assert changed.count("assembly_digest: packet_digest") == 1
            changed = changed.replace("assembly_digest: packet_digest",
                                      "assembly_digest: blake3_bytes_simd(changed_packet)")
        overlay = private / "changed-packet.vibe"
        overlay.write_text(changed)
        image = private / "compile.wasm"
        compile_env = dict(env, VIBE_RC="0", VIBE_FS_COMPILE="1", VIBE_WASM_NAMES="1",
            VIBE_WASM_KEEP_EXPORTS="1", VIBE_SOURCE_OVERLAY=str(target),
            VIBE_SOURCE_OVERLAY_WITH=str(overlay), VIBE_BUILD_CACHE_DIR=str(private / "compile-cache"))
        result = subprocess.run([str(runner), str(compiler), str(target), str(image), "__no_entry__"],
            cwd=repo, env=compile_env, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0 and image.is_file() and image.stat().st_size > 0, result
        assert image.read_bytes() != (artifacts / "compile.wasm").read_bytes()
        config = private / "service.json"
        config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
            "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(runner),
            "cwd": str(project), "directory": str(private), "jobs": 2}))
        output = private / "previous.wasm"
        output.write_bytes(b"previous build")
        selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_ENTRY="main",
            VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
            VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
            VIBE_LOWERING_OUTPUT=str(output), VIBE_BUILD_CACHE_DIR=str(private / "run-cache"))
        result = subprocess.run([str(runner), "--function-phases", str(image)], cwd=project,
            env=selected, capture_output=True, text=True, timeout=180)
        if bound:
            assert result.returncode == 0 and output.read_bytes() == expected.read_bytes(), result
        else:
            assert result.returncode != 0 and output.read_bytes() == b"previous build", result
            assert "function assembly: packet receipt differs" in result.stderr, result
    print("valid changed assembly is accepted only with its original returned receipt binding", flush=True)


def assert_completed_product_limit(artifacts, runner, env, project):
    """Individually admitted products can still exceed the whole result budget."""
    private = project / "product-pressure"
    private.mkdir()
    wrapper = private / "pressure-runner.py"
    wrapper.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
code = subprocess.call([os.environ["FUNCTION_PRESSURE_RUNNER"], *sys.argv[1:]])
plan_path = os.environ.get("VIBE_LOWERING_WORKERS")
if code == 0 and plan_path:
    plan = json.loads(Path(plan_path).read_text())
    jobs = [Path(p) for q in plan["queues"] for p in q]
    assert len(jobs) == 2
    sizes = []
    for job in jobs:
        product = Path(str(job) + ".product")
        before = product.stat().st_size
        with product.open("wb") as stream:
            stream.truncate(128 * 1024 * 1024 + 1)
        assert product.stat().st_size > before
        sizes.append(product.stat().st_size)
    Path(os.environ["FUNCTION_PRESSURE_RECORD"]).write_text(json.dumps(sizes))
sys.exit(code)
''')
    wrapper.chmod(0o755)
    config = private / "service.json"
    config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
        "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(wrapper),
        "cwd": str(project), "directory": str(private), "jobs": 2}))
    output, record = private / "previous.wasm", private / "sizes.json"
    output.write_bytes(b"previous build")
    selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_ENTRY="main",
        VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
        VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
        VIBE_LOWERING_OUTPUT=str(output), VIBE_BUILD_CACHE_DIR=str(private / "cache"),
        FUNCTION_PRESSURE_RUNNER=str(runner), FUNCTION_PRESSURE_RECORD=str(record))
    result = subprocess.run([str(runner), "--function-phases", str(artifacts / "compile.wasm")],
        cwd=project, env=selected, capture_output=True, text=True, timeout=180)
    sizes = json.loads(record.read_text())
    assert all(0 < n < 256 * 1024 * 1024 for n in sizes) and sum(sizes) > 256 * 1024 * 1024
    assert result.returncode != 0 and output.read_bytes() == b"previous build", result
    assert "completed phase products exceed256MiB" in result.stderr, result
    assert not (private / "service-report.json").exists()
    print("aggregate product pressure is refused before finisher/publication", flush=True)


def assert_phase_observation_cleanup(artifacts, runner, env, project, expected):
    """Real sampler/profiler Stores finish; parent FS counters never reach children."""
    for label, options in (
        ("sampled", {"VIBE_MEM": "1", "VIBE_MEM_SAMPLE_MS": "1"}),
        ("profiled", {}),
    ):
        private = project / ("phase-observation-" + label)
        private.mkdir()
        config = private / "service.json"
        config.write_text(json.dumps({"version": 1, "worker": str(artifacts / "worker.wasm"),
            "coordinator": str(artifacts / "coordinator.component.wasm"), "runner": str(runner),
            "cwd": str(project), "directory": str(private), "jobs": 2}))
        output = private / "out.wasm"
        profiles = private / "guest.json"
        if label == "profiled":
            options = {"VIBE_GUEST_PROFILE": str(profiles), "VIBE_GUEST_PROFILE_INTERVAL_US": "1000"}
        selected = dict(env, VIBE_LOWERING_INPUT="main.vibe", VIBE_LOWERING_ENTRY="main",
            VIBE_LOWERING_MODE="single", VIBE_FUNCTION_JOBS="2",
            VIBE_LOWERING_DIRECTORY=str(private), VIBE_LOWERING_SERVICE_CONFIG=str(config),
            VIBE_LOWERING_OUTPUT=str(output), VIBE_BUILD_CACHE_DIR=str(private / "cache"),
            VIBE_HOST_FS_SCOPE_OUT=str(private / "fs-scope.json"), VIBE_HOST_FS_SCOPE_NONCE=label,
            **options)
        result = subprocess.run([str(runner), "--function-phases", str(artifacts / "compile.wasm")],
            cwd=project, env=selected, capture_output=True, text=True, timeout=180)
        assert result.returncode == 0 and output.read_bytes() == expected.read_bytes(), result
        scope = json.loads((private / "fs-scope.json").read_text())
        assert scope["nonce"] == label and scope["read_file_calls"] > 0, scope
        report = json.loads((private / "service-report.json").read_text())
        assert report["preparation_store_dropped_before_workers"] and report["finisher_store_fresh"]
        if label == "sampled":
            assert result.stderr.count("vibe::mem ") == 2, result.stderr
        else:
            for phase in ("function_phase_prepare", "function_phase_finish"):
                path = Path(str(profiles) + "." + phase)
                assert isinstance(json.loads(path.read_text()), dict) and path.stat().st_size > 64
    print("actual sampler/profiler cleanup and parent-only filesystem counters preserve phase outputs", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("compiler", type=Path)
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    compiler, artifacts = args.compiler.resolve(), args.artifacts.resolve()
    runner = repo / "runtime/viberun/target/release/viberun"
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_CLI_WASM=str(compiler), VIBE_RUNNER=str(runner),
               VIBE_FUNCTION_ARTIFACT_DIR=str(artifacts), VIBE_UNSTABLE="1",
               VIBE_LIB=str(repo / "lib"), VIBE_RC="1", VIBE_CODEGEN_BODY_CACHE="off",
               VIBE_CHECKED_MODULE_CACHE="off", VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="1")
    with tempfile.TemporaryDirectory(prefix="vibe function CPU test ") as directory:
        project = Path(directory)
        long_name = "worker_identifier_" + "q" * 300
        cases = [
            ("long-identifier", f"fn {long_name}(a: Int) -> Int {{ a - 3 }}\nfn main() -> Int {{ {long_name}(11) }}", "8"),
            ("subtract", "fn sub(a: Int, b: Int) -> Int { a - b }\nfn main() -> Int { sub(43, 4) }", "39"),
            ("builtin-shadow", "fn compiler_lowering_run(n: Int) -> Int { n - 3 }\nfn main() -> Int { compiler_lowering_run(11) }", "8"),
            ("division", "fn quotient(a: Int, b: Int) -> Int { a / b }\nfn main() -> Int { quotient(43, 4) }", "10"),
            ("closures", "fn make(n: Int) -> (Int) -> Int { (x) -> { let inner = (y) -> y - n; inner(x) } }\nlet xs: Array[Int] = [9, 4]\nfn main() -> Int { let f = make(2); f(Array::get(xs, 0)) }", "7"),
            ("branch-closures", "fn choose(n: Int) -> (Int) -> Int { if n > 0 { (x) -> x - 2 } else { (x) -> x + 100 } }\nfn main() -> Int { let f = choose(1); f(9) }", "7"),
            ("exception", 'fn fail() -> Int with Exception { throw("expected") }\nfn main() -> Int { handle { fail() } with { Exception::Throw(_) => 17 } }', "17"),
            ("large-string", 'let value: String = "' + "z" * 131072 + 'é🍣"\nfn main() -> Int { String::length(value) }', "131078"),
        ]

        def build(label, jobs=None, extra=None, expected=0):
            output, trace = project / f"{label}.wasm", project / f"{label}.json"
            current = dict(env, VIBE_BUILD_CACHE_DIR=str(project / f"{label}-cache"),
                           VIBE_FUNCTION_TRACE_OUT=str(trace))
            flags = []
            if jobs is not None:
                flags = ["--jobs", str(jobs)]
                current["VIBE_TASKGROUP_FUNCTIONS"] = "1"
            current.update(extra or {})
            result = subprocess.run(["bash", str(repo / "runtime/vibe"), "build", "main.vibe",
                                     "-o", str(output), *flags], cwd=project, env=current,
                                    capture_output=True, text=True, timeout=180)
            assert result.returncode == expected, (label, result.stdout, result.stderr)
            return output, trace, result

        for case, source, answer in cases:
            (project / "main.vibe").write_text(source)
            control, _, _ = build(f"{case}-serial")
            for jobs in (1, 2, 4):
                output, trace, _ = build(f"{case}-jobs{jobs}", jobs)
                assert output.read_bytes() == control.read_bytes(), (case, jobs, "Wasm differs")
                report = json.loads(trace.read_text())
                assert report["kind"] == "vibe-taskgroup-functions", report
                assert report["workers"] == jobs and report["range_jobs"] == jobs, report
                assert report["functions"] > 0 and report["preparation_count"] == 1, report
                assert report["preparation_store_dropped_before_workers"] and report["finisher_store_fresh"], report
                assert report["finisher_source_reads"] == 0, report
                assert 0 < report["completed_product_bytes"] <= 256 * 1024 * 1024, report
                assert len(report["original_phase_receipt_sha256"]) == 64, report
                assert report["context_serialization_count"] == 1 and report["shared_context_bytes"] <= 64 * 1024 * 1024, report
                assert "modules" not in report and "isolated" in report["phase_scope"], report
                if case == "closures":
                    assert report["lambdas"] >= 2, report
                result = subprocess.run([str(runner), str(output)], capture_output=True, text=True, timeout=30)
                assert result.returncode == 0 and result.stdout.strip() == answer, (case, jobs, result)
            print(f"{case}: ordinary == 1/2/4 CPU workers; execution correct", flush=True)

        # Catch the original wire4/receipt3 drift using actual guest bytes.
        # Updating both publisher and frontend constants cannot hide a drift.
        assert_context_receipt_format(artifacts, runner, env, project, "wire-format", control)
        assert_packet_integrity(repo, artifacts, runner, env, project)
        assert_finisher_recompile_refused(repo, compiler, artifacts, runner, env, project)
        assert_original_phase_receipt_bound(repo, compiler, artifacts, runner, env, project, control)
        assert_phase_observation_cleanup(artifacts, runner, env, project, control)
        assert_completed_product_limit(artifacts, runner, env, project)

        # A refused setting or changed image must leave a previous build intact.
        for label, extra in [
            ("coverage", {"VIBE_COVERAGE": "1"}),
            ("gc", {"VIBE_BACKEND": "gc"}),
            ("body-cache", {"VIBE_CODEGEN_BODY_CACHE": "on"}),
            ("mixed-phases", {"VIBE_TASKGROUP_LOWERING": "1"}),
        ]:
            output = project / f"{label}.wasm"
            output.write_bytes(b"previous build")
            build(label, 2, extra, expected=1)
            assert output.read_bytes() == b"previous build", label

        for alias in ("direct", "symlink", "hardlink"):
            label = f"trace-{alias}"
            output = project / f"{label}.wasm"
            output.write_bytes(b"previous build")
            trace = output
            if alias != "direct":
                trace = project / f"{label}-alias.json"
                if alias == "symlink":
                    trace.symlink_to(output)
                else:
                    os.link(output, trace)
            _, _, result = build(label, 2, {"VIBE_FUNCTION_TRACE_OUT": str(trace)}, expected=1)
            assert "must not alias" in result.stderr and output.read_bytes() == b"previous build", result

        changed = project / "changed-images"
        shutil.copytree(artifacts, changed, ignore=shutil.ignore_patterns("compile-cache"))
        worker = changed / "worker.wasm"
        worker.write_bytes(worker.read_bytes() + b"changed")
        output = project / "changed.wasm"
        output.write_bytes(b"previous build")
        _, _, result = build("changed", 2, {"VIBE_FUNCTION_ARTIFACT_DIR": str(changed)}, expected=1)
        assert "image changed" in result.stderr and output.read_bytes() == b"previous build", result
        worker.write_bytes((artifacts / "worker.wasm").read_bytes())
        receipt_path = changed / "build.json"
        receipt = json.loads(receipt_path.read_text())
        stale = dict(receipt, context_format=3)
        receipt_path.write_text(json.dumps(stale))
        try:
            assert_context_receipt_format(changed, runner, env, project, "wire-format-stale", control)
        except AssertionError as error:
            assert str(error) == "context wire/receipt mismatch", error
        else:
            raise AssertionError("the real wire/receipt drift must be detected")
        for version in (3, 4, 5, 6):
            stale = dict(receipt, context_format=version)
            receipt_path.write_text(json.dumps(stale))
            label = f"context-format-{version}"
            output = project / f"{label}.wasm"
            output.write_bytes(b"previous build")
            _, _, result = build(label, 2, {"VIBE_FUNCTION_ARTIFACT_DIR": str(changed)}, expected=1)
            assert "callback ABI" in result.stderr and output.read_bytes() == b"previous build", result
        receipt_path.write_text(json.dumps(dict(receipt, function_abi="bump-core-tagged-callbacks-1")))
        output = project / "legacy-digests.wasm"
        output.write_bytes(b"previous build")
        _, _, result = build("legacy-digests", 2, {"VIBE_FUNCTION_ARTIFACT_DIR": str(changed)}, expected=1)
        assert "callback ABI" in result.stderr and output.read_bytes() == b"previous build", result
        receipt["compile_engine_rc"] = 1
        receipt_path.write_text(json.dumps(receipt))
        output = project / "abi.wasm"
        output.write_bytes(b"previous build")
        _, _, result = build("abi", 2, {"VIBE_FUNCTION_ARTIFACT_DIR": str(changed)}, expected=1)
        assert "callback ABI" in result.stderr and output.read_bytes() == b"previous build", result
        (project / "main.vibe").write_text('fn main() -> Int { "wrong type" }')
        output = project / "invalid-source.wasm"
        output.write_bytes(b"previous build")
        build("invalid-source", 2, expected=1)
        assert output.read_bytes() == b"previous build"
        (project / "main.vibe").write_text(cases[0][1])

        # A valid, receipt-bound module traps inside each real CPU worker.
        # This reaches TaskGroup failure handling instead of the image hash guard.
        def section(kind, data):
            assert len(data) < 128
            return bytes([kind, len(data)]) + data

        def export(name, kind):
            text = name.encode()
            return bytes([len(text)]) + text + bytes([kind, 0])

        trap = b"\0asm\x01\0\0\0"
        trap += section(1, bytes([1, 0x60, 0, 0]))
        trap += section(3, bytes([1, 0]))
        trap += section(5, bytes([1, 0, 1]))
        trap += section(7, bytes([3]) + export("_start", 0) + export("main", 0) + export("memory", 2))
        trap += section(10, bytes([1, 3, 0, 0, 0x0b]))
        worker.write_bytes(trap)
        receipt = json.loads((artifacts / "build.json").read_text())
        receipt["artifacts"]["worker.wasm"] = hashlib.sha256(trap).hexdigest()
        receipt_path.write_text(json.dumps(receipt))
        output = project / "worker-failure.wasm"
        output.write_bytes(b"previous build")
        _, trace, result = build("worker-failure", 4, {"VIBE_FUNCTION_ARTIFACT_DIR": str(changed)}, expected=1)
        assert "coordinator exited" in result.stderr, result
        assert output.read_bytes() == b"previous build" and not trace.exists(), result
        print("unsupported settings, aliases, stale ABI, invalid source and native worker failure preserve previous output", flush=True)


if __name__ == "__main__":
    main()

"""Exercise real CLI CPU workers, byte parity, execution and atomic refusals."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


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
                assert report["context_serialization_count"] == 1 and report["shared_context_bytes"] <= 64 * 1024 * 1024, report
                assert "modules" not in report and "isolated" in report["phase_scope"], report
                if case == "closures":
                    assert report["lambdas"] >= 2, report
                result = subprocess.run([str(runner), str(output)], capture_output=True, text=True, timeout=30)
                assert result.returncode == 0 and result.stdout.strip() == answer, (case, jobs, result)
            print(f"{case}: ordinary == 1/2/4 CPU workers; execution correct", flush=True)

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

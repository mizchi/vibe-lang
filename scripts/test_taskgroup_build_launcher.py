"""Exercise the public build door with current compiler and native worker images."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("compiler", type=Path)
    parser.add_argument("artifacts", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    compiler, artifacts = args.compiler.resolve(), args.artifacts.resolve()
    runner = repo / "runtime/viberun/target/release/viberun"
    launcher = repo / "runtime/vibe"
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_CLI_WASM=str(compiler), VIBE_RUNNER=str(runner),
               VIBE_TASKGROUP_ARTIFACT_DIR=str(artifacts), VIBE_LIB=str(repo / "lib"))
    with tempfile.TemporaryDirectory(prefix="vibe public build ") as directory:
        project = Path(directory)
        (project / "left.vibe").write_text("export fn left() -> Int { 25 }\n")
        (project / "right.vibe").write_text("export fn right() -> Int { 17 }\n")
        (project / "main.vibe").write_text(
            "import ./left.vibe { left }\nimport ./right.vibe { right }\n"
            "export fn main() -> Int { left() + right() }\n")

        def build(label, flags, expected=0, extra=None):
            output = project / (label + ".wasm")
            trace = project / (label + ".trace.json")
            current = {**env, "VIBE_BUILD_CACHE_DIR": str(project / (label + "-cache")),
                       "VIBE_TASKGROUP_TRACE_OUT": str(trace), **(extra or {})}
            result = subprocess.run(["bash", str(launcher), "build", "main.vibe", "-o", str(output), *flags],
                                    cwd=project, env=current, text=True, capture_output=True, timeout=120)
            assert result.returncode == expected, (label, result.stdout, result.stderr)
            if expected:
                assert not output.exists(), label
            return output, trace, result

        control, _, _ = build("serial", [])
        for jobs in [1, 2, 4]:
            output, trace, _ = build(f"jobs{jobs}", ["--jobs", str(jobs)])
            assert output.read_bytes() == control.read_bytes(), "public build Wasm parity"
            report = json.loads(trace.read_text())
            assert report["modules"] == report["checked"] == report["warmed"] == 3, report
            assert report["diagnosed"] == report["blocked"] == 0, report
        run = subprocess.run([str(runner), str(output)], text=True, capture_output=True, check=True)
        assert run.stdout.strip() == "42", run
        for flags in [["--jobs"], ["--jobs", "0"], ["--jobs", "3"], ["--jobs", "2", "--debug"],
                      ["--jobs", "2", "--wit"], ["--jobs", "2", "--component"]]:
            _, trace, result = build("invalid", flags, expected=1)
            assert not trace.exists() and result.stderr.strip(), result
        # A real native query can write a valid plan before its process fails.
        # Fault-inject after that success, without replacing the compiler output.
        proxy = project / "query-failure-runner.py"
        query_completed = project / "query-completed"
        coordinator_started = project / "coordinator-started"
        proxy.write_text(
            f"#!{sys.executable}\n"
            "import os, subprocess, sys\nfrom pathlib import Path\n"
            "if Path(sys.argv[1]).name == 'coordinator.component.wasm':\n"
            f"    Path({str(coordinator_started)!r}).touch()\n"
            f"result = subprocess.run([{str(runner)!r}, *sys.argv[1:]])\n"
            "if os.environ.get('VIBE_MODULE_PLAN') == '1' and result.returncode == 0:\n"
            f"    Path({str(query_completed)!r}).touch()\n"
            "    sys.exit(7)\n"
            "sys.exit(result.returncode)\n"
        )
        proxy.chmod(0o755)
        _, trace, result = build("query-failed-after-plan", ["--jobs", "2"], expected=1,
                                 extra={"VIBE_RUNNER": str(proxy)})
        assert query_completed.exists(), "the real native query was not fault-injected"
        assert not coordinator_started.exists() and not trace.exists(), result
        assert "VIBE_MODULE_PLAN" in result.stderr and "exit 7" in result.stderr, result
        _, _, result = build("missing-images", ["--jobs", "2"], expected=1,
                             extra={"VIBE_TASKGROUP_ARTIFACT_DIR": str(project / "absent")})
        assert "TaskGroup images are missing" in result.stderr, result
        damaged = project / "damaged-images"
        damaged.mkdir()
        for name in ["worker.wasm", "coordinator.component.wasm", "build.json"]:
            shutil.copyfile(artifacts / name, damaged / name)
        receipt = json.loads((damaged / "build.json").read_text())
        receipt["compiler_sha256"] = "0" * 64
        (damaged / "build.json").write_text(json.dumps(receipt))
        _, _, result = build("wrong-compiler-images", ["--jobs", "2"], expected=1,
                             extra={"VIBE_TASKGROUP_ARTIFACT_DIR": str(damaged)})
        assert "different compiler" in result.stderr, result
        shutil.copyfile(artifacts / "build.json", damaged / "build.json")
        with (damaged / "worker.wasm").open("ab") as handle:
            handle.write(b"changed")
        _, _, result = build("changed-worker", ["--jobs", "2"], expected=1,
                             extra={"VIBE_TASKGROUP_ARTIFACT_DIR": str(damaged)})
        assert "does not match its build receipt" in result.stderr, result
        prefix = project / "installed"
        install = subprocess.run([
            "bash", str(repo / "install/install.sh"), "--__vibe-install-root", str(repo),
            "--runner", str(runner), "--cli-wasm", str(compiler), "--taskgroup-artifacts", str(artifacts),
            "--prefix", str(prefix), "--toolchain", "dogfood", "--no-link", "--no-modify-path", "--no-stdlib"
        ], env=env, text=True, capture_output=True, timeout=120)
        assert install.returncode == 0, (install.stdout, install.stderr)
        installed = prefix / "toolchains/dogfood/bin/vibe"
        standalone = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
        standalone.update(VIBE_TASKGROUP_TRACE_OUT=str(project / "installed.trace.json"),
                          VIBE_BUILD_CACHE_DIR=str(project / "installed-cache"))
        result = subprocess.run([
            "bash", str(installed), "build", "main.vibe", "--jobs", "4", "-o", str(project / "installed.wasm")
        ], cwd=project, env=standalone, text=True, capture_output=True, timeout=120)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert (project / "installed.wasm").read_bytes() == control.read_bytes()
        report = json.loads((project / "installed.trace.json").read_text())
        assert report["modules"] == report["checked"] == report["warmed"] == 3, report
        (project / "right.vibe").write_text('export fn right() -> Int { "wrong" }\n')
        _, _, serial = build("diagnosed-serial", [], expected=1)
        _, trace, parallel = build("diagnosed-parallel", ["--jobs", "2"], expected=1)
        assert serial.stderr == parallel.stderr, (serial, parallel)
        report = json.loads(trace.read_text())
        assert report["diagnosed"] > 0 and report["blocked"] > 0, report
        print("public build --jobs: native TaskGroup, parity, validation, missing images, diagnostics pass")
        print("control sha256", hashlib.sha256(control.read_bytes()).hexdigest())


if __name__ == "__main__":
    main()

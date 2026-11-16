"""Check actual public native builds reuse successful CPU products when enabled."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile


def check_direct_product_rejections(repo, project, compiler, images, env):
    # Keep one successful handoff so the same final compiler can exercise
    # mutations against real bytes and a real module fingerprint.
    source = project / "producer.vibe"
    original_source = "export fn main() -> Int { 42 }\n"
    source.write_text(original_source)
    trace = project / "direct-product.json"
    output = project / "direct-product.wasm"
    common = {**env, "VIBE_PREOPEN_DIR": str(project), "VIBE_BUILD_CACHE_DIR": str(project / "direct-product-cache"),
              "VIBE_TASKGROUP_TRACE_OUT": str(trace)}
    completed = subprocess.run([
        "bash", str(repo / "scripts/build_taskgroup_project.sh"), str(compiler), source.name,
        str(output), "main", "4", str(images),
    ], cwd=project, env={**common, "VIBE_TASKGROUP_KEEP_JOBS": "1"}, text=True, capture_output=True, timeout=120)
    assert completed.returncode == 0, (completed.stdout, completed.stderr)
    report = json.loads(trace.read_text())
    assert report["handoff"] == "direct" and report["checked"] == 1, report
    work = Path(report["work"])
    try:
        directory = work / "checked-products"
        product, = [path for path in directory.iterdir() if path.name != "accepted"]
        raw = product.read_bytes()
        expected_wasm = output.read_bytes()
        output.unlink()
        # The raw adapter's output is separate from the public launcher.
        command = [
            "bash", str(repo / "scripts/run_wasm_vibe_host_runner.sh"), "--invoke", "cli_main",
            str(compiler), source.name, str(output), "main",
        ]
        check_env = {**common, "VIBE_TASKGROUP_CHECKED_PRODUCTS_DIR": str(directory),
                     "VIBE_FS_COMPILE": "1", "VIBE_IMPORT_ABI": "raw", "VIBE_RUNNER_EXIT_WITH_RESULT": "1",
                     "VIBE_TASKGROUP_INTERFACE_REPLAY": "1"}

        def rejects(expected, extra=None):
            diagnostic = output.with_suffix(".wasm.diag")
            diagnostic.unlink(missing_ok=True)
            result = subprocess.run(command, cwd=project, env={**check_env, **(extra or {})}, text=True, capture_output=True, timeout=120)
            assert result.returncode != 0 and not output.exists(), (result.stdout, result.stderr)
            combined = result.stdout + result.stderr + (diagnostic.read_text() if diagnostic.exists() else "")
            assert expected in combined, combined

        for options in ({}, {"VIBE_TASKGROUP_HOST_SHA256": "0"}):
            result = subprocess.run(command, cwd=project, env={**check_env, **options}, text=True, capture_output=True, timeout=120)
            assert result.returncode == 0 and output.read_bytes() == expected_wasm, (result.stdout, result.stderr)
            output.unlink()

        product.unlink()
        rejects("missing TaskGroup checked product")
        product.write_bytes(raw + b"trailing bytes")
        rejects("unreadable TaskGroup checked product")
        product.write_bytes(raw)
        rejects("stale TaskGroup checked product", {"VIBE_CHECK_ERROR_ROW": "0"})
        rejects("stale TaskGroup checked product", {"VIBE_CFG": "dev"})
        source.write_text(original_source.replace("42", "43"))
        rejects("stale TaskGroup checked product")

        # A prepared ledger is insufficient on its own. Revoke acceptance
        # and remove the existing replay entry so accidental publication is
        # observable even when the attempted write would be byte-identical.
        ledger = json.loads((work / "pending-replay.json").read_text())
        key, _ = ledger["fresh"][0]
        replay_record = Path(ledger["cache"]["root"]) / f"{key}.json"
        replay_record.unlink()
        (directory / "accepted").unlink()
        rejected = subprocess.run([
            "node", str(repo / "scripts/taskgroup_frontend_warm.mjs"), "--commit-direct", str(work),
        ], cwd=project, env=common, text=True, capture_output=True, timeout=120)
        assert rejected.returncode != 0 and not replay_record.exists(), (rejected.stdout, rejected.stderr)
    finally:
        shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("compiler", type=Path)
    parser.add_argument("artifacts", type=Path)
    parser.add_argument("--direct", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runner = repo / "runtime/viberun/target/release/viberun"
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_CLI_WASM=str(args.compiler.resolve()), VIBE_RUNNER=str(runner),
               VIBE_TASKGROUP_ARTIFACT_DIR=str(args.artifacts.resolve()), VIBE_LIB=str(repo / "lib"),
               VIBE_TASKGROUP_JOB_CACHE="1", VIBE_TASKGROUP_DIRECT="1" if args.direct else "0")
    with tempfile.TemporaryDirectory(prefix="vibe public replay ") as directory:
        project = Path(directory)
        (project / "left.vibe").write_text("export fn left() -> Int { 25 }\n")
        (project / "right.vibe").write_text("export fn right() -> Int { 17 }\n")
        (project / "main.vibe").write_text(
            "import ./left.vibe { left }\nimport ./right.vibe { right }\n"
            "export fn main() -> Int { left() + right() }\n")
        env["VIBE_BUILD_CACHE_DIR"] = str(project / "cache")

        def build(label, extra=None, expected=0):
            output, trace = project / (label + ".wasm"), project / (label + ".json")
            current = {**env, "VIBE_TASKGROUP_TRACE_OUT": str(trace), **(extra or {})}
            current = {k: v for k, v in current.items() if v is not None}
            result = subprocess.run([
                "bash", str(repo / "runtime/vibe"), "build", "main.vibe", "--jobs", "4", "-o", str(output)
            ], cwd=project, env=current,
                text=True, capture_output=True, timeout=120)
            assert result.returncode == expected, (label, result.stdout, result.stderr)
            if expected:
                assert not output.exists(), label
            report = json.loads(trace.read_text())
            assert report["handoff"] == ("direct" if args.direct and not expected else "published"), report
            return output.read_bytes() if not expected else result.stderr, report

        cold, cold_report = build("cold")
        assert cold_report["checked"] == cold_report["warmed"] == 3
        assert any(e["event"] == "finished" for w in cold_report["waves"] for e in w["events"])
        warm, warm_report = build("warm")
        assert warm == cold, "warm public build changed Wasm bytes"
        assert not any(e["event"] == "finished" for w in warm_report["waves"] for e in w["events"]), \
            "warm public build still starts CPU workers"
        assert warm_report["executed"] == 0 and warm_report["reused"] == 3, warm_report
        changed = "export fn right() -> Int { 18 }\n"
        assert changed != (project / "right.vibe").read_text(), "source mutation did not land"
        (project / "right.vibe").write_text(changed)
        edited, edited_report = build("edited")
        assert edited != cold
        expected_checks = 1 if args.direct else 2
        assert edited_report["executed"] == expected_checks and edited_report["reused"] == 3 - expected_checks, edited_report
        control, control_report = build("control", {"VIBE_TASKGROUP_JOB_CACHE": "0"})
        assert edited == control and control_report["executed"] == 3, control_report
        if args.direct:
            (project / "right.vibe").write_text("export fn right() -> Bool { true }\n")
            _, public_edit = build("changed-interface", expected=1)
            assert public_edit["executed"] == 2 and public_edit["diagnosed"] == 1, public_edit
            (project / "right.vibe").write_text(changed)
        for label, expected in [("cfg-cold", 3), ("cfg-warm", 0)]:
            _, report = build(label, {"VIBE_CFG": "dev"})
            assert report["executed"] == expected, report
        for index, override in enumerate(["", None]):
            for temperature, expected in [("cold", 3), ("warm", 0)]:
                _, report = build(f"default-{index}-{temperature}", {"VIBE_BUILD_CACHE_DIR": override})
                assert report["executed"] == expected, report
            assert list((project / ".vibe/build/cache/taskgroup-jobs-v1").glob("*.json"))
            assert not (project / "taskgroup-jobs-v1").exists(), "empty override escaped the default cache"

        corrupt_cache = project / "corrupt-cache"
        corrupt_env = {"VIBE_BUILD_CACHE_DIR": str(corrupt_cache)}
        original, _ = build("corrupt-cold", corrupt_env)
        entry = next((corrupt_cache / "taskgroup-jobs-v1").glob("*.json"))
        record = json.loads(entry.read_text())
        assert record["version"] == 1, "corruption mutation did not land"
        record["version"] = 999
        entry.write_text(json.dumps(record))
        repaired, report = build("corrupt-repaired", corrupt_env)
        assert repaired == original and report["executed"] == 1 and report["reused"] == 2, report

        images = project / "producer-images"
        images.mkdir()
        for name in ["worker.wasm", "coordinator.component.wasm", "build.json"]:
            shutil.copyfile(args.artifacts.resolve() / name, images / name)
        image_env = {"VIBE_TASKGROUP_ARTIFACT_DIR": str(images)}
        _, report = build("producer-cold", image_env)
        assert report["executed"] == 3, report
        _, report = build("producer-warm", image_env)
        assert report["executed"] == 0, report
        worker = images / "worker.wasm"
        before = worker.read_bytes()
        name = b"replay-control"
        worker.write_bytes(before + bytes([0, len(name) + 1, len(name)]) + name)
        assert worker.read_bytes() != before, "producer mutation did not land"
        receipt = json.loads((images / "build.json").read_text())
        key, = [p for p in receipt["artifacts"] if Path(p).name == "worker.wasm"]
        receipt["artifacts"][key] = hashlib.sha256(worker.read_bytes()).hexdigest()
        (images / "build.json").write_text(json.dumps(receipt))
        after, report = build("producer-changed", image_env)
        assert after == edited and report["executed"] == 3, report
        _, report = build("producer-changed-warm", image_env)
        assert report["executed"] == 0, report

        prefix = project / "installed"
        install = subprocess.run([
            "bash", str(repo / "install/install.sh"), "--__vibe-install-root", str(repo),
            "--runner", str(runner), "--cli-wasm", str(args.compiler.resolve()),
            "--taskgroup-artifacts", str(args.artifacts.resolve()), "--prefix", str(prefix),
            "--toolchain", "replay", "--no-link", "--no-modify-path", "--no-stdlib"
        ], env=env, text=True, capture_output=True, timeout=120)
        assert install.returncode == 0, (install.stdout, install.stderr)
        installed_env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
        installed_env.update(VIBE_TASKGROUP_JOB_CACHE="1", VIBE_TASKGROUP_DIRECT=env["VIBE_TASKGROUP_DIRECT"],
                             VIBE_BUILD_CACHE_DIR=str(project / "installed-cache"))
        for temperature, expected in [("cold", 3), ("warm", 0)]:
            output = project / f"installed-{temperature}.wasm"
            trace = project / f"installed-{temperature}.json"
            result = subprocess.run([
                "bash", str(prefix / "toolchains/replay/bin/vibe"), "build", "main.vibe",
                "--jobs", "4", "-o", str(output)
            ], cwd=project, env={**installed_env, "VIBE_TASKGROUP_TRACE_OUT": str(trace)},
                text=True, capture_output=True, timeout=120)
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert output.read_bytes() == edited, "standalone installed replay changed output"
            report = json.loads(trace.read_text())
            assert report["executed"] == expected and report["reused"] == 3 - expected, report
            assert report["handoff"] == ("direct" if args.direct else "published"), report

        if args.direct:
            check_direct_product_rejections(repo, project, args.compiler.resolve(), args.artifacts.resolve(), env)

        (project / "right.vibe").write_text('export fn right() -> Int { "wrong" }\n')
        first, report = build("diagnosed-first", expected=1)
        assert report["diagnosed"] == report["blocked"] == report["executed"] == report["reused"] == 1, report
        repeated, report = build("diagnosed-again", expected=1)
        assert first == repeated and report["executed"] == report["diagnosed"] == 1, report
        assert report["reused"] == report["blocked"] == 1, report
        print("public replay: cold/warm, body edits, context, empty overrides, corruption, producer changes and diagnostics pass")


if __name__ == "__main__":
    main()

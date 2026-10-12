"""Real CLI parity, wave bounds and refusal before publishing partial output."""
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
    runner = repo / "runtime/viberun/target/release/viberun"
    compiler, artifacts = args.compiler.resolve(), args.artifacts.resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_CLI_WASM=str(compiler), VIBE_RUNNER=str(runner),
               VIBE_LOWERING_ARTIFACT_DIR=str(artifacts), VIBE_UNSTABLE="1",
               VIBE_LIB=str(repo / "lib"), VIBE_RC="1")
    with tempfile.TemporaryDirectory(prefix="vibe lowering test ",
                                     dir=os.environ.get("VIBE_LOWERING_TEST_TMPDIR")) as directory:
        project = Path(directory)
        for i in range(66):
            (project / f"m{i}.vibe").write_text(f"export fn f{i}() -> Int {{ {i} }}\n")
        source = "".join(f"import ./m{i}.vibe {{ f{i} }}\n" for i in range(66))
        source += "export fn main() -> Int { " + " + ".join(f"f{i}()" for i in range(66)) + " }\n"
        (project / "main.vibe").write_text(source)

        def build(label, flags, extra=None, expected=0):
            output, trace = project / f"{label}.wasm", project / f"{label}.json"
            current = dict(env, VIBE_BUILD_CACHE_DIR=str(project / f"{label}-cache"),
                           VIBE_LOWERING_TRACE_OUT=str(trace))
            current.update(extra or {})
            result = subprocess.run(["bash", str(repo / "runtime/vibe"), "build", "main.vibe",
                                     "-o", str(output), *flags], cwd=project, env=current,
                                    capture_output=True, text=True, timeout=180)
            assert result.returncode == expected, (label, result.stdout, result.stderr)
            return output, trace, result

        control, _, _ = build("serial", [])
        # The new unqualified builtin must remain shadowable by source code.
        for rc in ["0", "1"]:
            shadow_output = project / f"shadow-{rc}.wasm"
            current = dict(env, VIBE_RC=rc, VIBE_FS_COMPILE="1", VIBE_IMPORT_ABI="raw",
                           VIBE_PREOPEN_DIR=str(repo), VIBE_BUILD_CACHE_DIR=str(project / f"shadow-{rc}-cache"))
            result = subprocess.run([str(runner), str(compiler),
                str(repo / "fixtures/rc_user_shadowed_lowering_service_test.vibe"),
                str(shadow_output), "main"], env=current, capture_output=True, text=True, timeout=180)
            assert result.returncode == 0, result
            result = subprocess.run([str(runner), str(shadow_output)], capture_output=True, text=True)
            assert result.returncode == 0 and result.stdout.strip() == "8", result
        for jobs in [1, 2, 4]:
            output, trace, _ = build(f"jobs{jobs}", ["--jobs", str(jobs)],
                                     {"VIBE_TASKGROUP_LOWERING": "1"})
            assert output.read_bytes() == control.read_bytes(), f"Wasm differs: {jobs} workers"
            report = json.loads(trace.read_text())
            assert report["modules"] == 67 and report["workers"] == jobs, report
            assert report["preparation_count"] == 1 and report["replay_ms"] == 0, report
            assert report["finalize_ms"] > 0 and "encoding" in report["phase_scope"], report
            assert len(report["waves"]) >= 2, report
            assert report["peak_queued_jobs"] <= 16 * jobs, report
            assert report["peak_queued_input_bytes"] <= 64 * 1024 * 1024, report
        empty_cache, trace, _ = build("empty-cache", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_BUILD_CACHE_DIR": ""})
        assert empty_cache.read_bytes() == control.read_bytes(), empty_cache
        assert json.loads(trace.read_text())["preparation_count"] == 1, trace
        default_build = subprocess.run(["bash", str(repo / "runtime/vibe"), "build", "main.vibe", "--jobs", "2"],
            cwd=project, env=dict(env, VIBE_TASKGROUP_LOWERING="1"), capture_output=True, text=True, timeout=180)
        assert default_build.returncode == 0, default_build
        defaults = list((project / ".vibe/build/out").glob("*.wasm"))
        assert len(defaults) == 1 and defaults[0].read_bytes() == control.read_bytes(), defaults
        result = subprocess.run([str(runner), str(output)], capture_output=True, text=True, check=True)
        assert result.stdout.strip() == "2145", result

        for alias in ["direct", "symlink", "hardlink", "parent-symlink"]:
            label = f"trace-{alias}"
            target = project / f"{label}.wasm"
            target.write_bytes(b"keep previous output")
            trace_alias = target
            if alias == "symlink":
                trace_alias = project / "trace-link.json"
                trace_alias.symlink_to(target)
            elif alias == "hardlink":
                trace_alias = project / "trace-hardlink.json"
                os.link(target, trace_alias)
            elif alias == "parent-symlink":
                link = project / "trace-parent"
                link.symlink_to(project, target_is_directory=True)
                trace_alias = link / target.name
            output, _, result = build(label, ["--jobs", "2"],
                {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(trace_alias)}, expected=1)
            assert "trace must not alias the build output" in result.stderr, result
            assert output.read_bytes() == b"keep previous output" and trace_alias.exists(), result

        absent = project / "trace-absent.wasm"
        output, _, result = build("trace-absent", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": "trace-parent/trace-absent.wasm"}, expected=1)
        assert "trace must not alias the build output" in result.stderr and not absent.exists(), result

        if (project / "JOBS2.WASM").exists():
            for existing in [False, True]:
                label = f"casefold-{existing}"
                target = project / f"{label}.wasm"
                trace_alias = project / target.name.upper()
                if existing:
                    target.write_bytes(b"keep previous output")
                output, _, result = build(label, ["--jobs", "2"],
                    {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(trace_alias)}, expected=1)
                assert "trace must not alias the build output" in result.stderr, result
                if existing:
                    assert output.read_bytes() == b"keep previous output", result
                else:
                    assert not output.exists() and not trace_alias.exists(), result
            print("TaskGroup lowering: existing and absent case-folded aliases refused")

        for alias in ["direct", "symlink", "hardlink"]:
            trace_alias = project / "main.vibe"
            if alias != "direct":
                trace_alias = project / f"source-{alias}.json"
                if alias == "symlink":
                    trace_alias.symlink_to(project / "main.vibe")
                else:
                    os.link(project / "main.vibe", trace_alias)
            _, _, result = build(f"source-{alias}", ["--jobs", "2"],
                {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(trace_alias)}, expected=1)
            assert "trace must not alias the source entry" in result.stderr, result
            assert (project / "main.vibe").read_text() == source and trace_alias.exists(), result
        imported = project / "m0.vibe"
        previous = imported.read_bytes()
        _, _, result = build("source-import", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(imported)}, expected=1)
        assert "not a lowering report" in result.stderr and imported.read_bytes() == previous, result

        target = project / "trace-write-refusal.wasm"
        target.write_bytes(b"keep previous output")
        output, _, result = build("trace-write-refusal", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(project / "missing-parent/report.json")}, expected=1)
        assert "ENOENT" in result.stderr and output.read_bytes() == b"keep previous output", result

        # A prior report from this route is reusable; arbitrary files are not.
        reusable = project / "reusable.json"
        reusable.write_text((project / "jobs2.json").read_text())
        output, _, _ = build("trace-reuse", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_LOWERING_TRACE_OUT": str(reusable)})
        assert output.read_bytes() == control.read_bytes(), output

        # Exercise the real frontend with the old PID-derived staging name
        # pre-existing as a symlink. Neither success nor failure may follow it.
        protected = project / "protected-user-data"
        protected.write_bytes(b"user data must remain unchanged")
        probe = """
import { symlink, rm } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
const [frontend, compiler, input, output, root, artifacts, runner, protectedPath] = process.argv.slice(2);
const oldStaging = output + `.lowering-${process.pid}.tmp`;
await symlink(protectedPath, oldStaging);
try {
  const { buildTaskGroupLowering } = await import(pathToFileURL(frontend));
  await buildTaskGroupLowering({ compiler, input, output, entry: 'main', jobs: 2, root, artifacts, runner });
} finally { await rm(oldStaging, { force: true }); }
"""
        for failure in [False, True]:
            target = project / f"staging-{failure}.wasm"
            if failure:
                target.write_bytes(b"keep previous output")
            trace = project / ("missing-parent/staging-report.json" if failure else "staging-report.json")
            result = subprocess.run(["node", "--input-type=module", "-e", probe, "staging-probe",
                str(repo / "scripts/taskgroup_lowering_frontend.mjs"), str(compiler), "main.vibe",
                str(target), str(project), str(artifacts), str(runner), str(protected)],
                cwd=project, env=dict(env, VIBE_LOWERING_TRACE_OUT=str(trace)),
                capture_output=True, text=True, timeout=180)
            assert result.returncode == (1 if failure else 0), result
            assert protected.read_bytes() == b"user data must remain unchanged", result
            assert target.read_bytes() == (b"keep previous output" if failure else control.read_bytes()), result
            assert not list(project.glob(".vibe-lowering-output-*")), project

        for label, extra, flags, message in [
            ("stable-refusal", {"VIBE_UNSTABLE": "0"}, [], "requires VIBE_UNSTABLE=1"),
            ("bump-refusal", {"VIBE_RC": "0"}, [], "requires the RC backend"),
            ("minify-refusal", {}, ["--minify"], "does not yet support --minify"),
        ]:
            target = project / f"{label}.wasm"
            target.write_bytes(b"keep previous output")
            output, _, result = build(label, ["--jobs", "2", *flags],
                                      {"VIBE_TASKGROUP_LOWERING": "1", **extra}, expected=1)
            assert output.read_bytes() == b"keep previous output" and message in result.stderr, result

        # Mutation after a real preparation must refuse before publishing.
        proxy = project / "runner.py"
        proxy.write_text(f"#!{sys.executable}\nimport subprocess,sys,os,json\nfrom pathlib import Path\n"
                         "if Path(sys.argv[1]).name == 'coordinator.component.wasm':\n"
                         " if os.environ.get('LOWERING_TEST_MUTATION') == 'job':\n"
                         "  plan=json.loads(Path(os.environ['VIBE_LOWERING_WORKERS']).read_text())\n"
                         "  p=Path(next(p for q in plan['queues'] for p in q))\n"
                         "  p.write_bytes(p.read_bytes().replace(b'f0',b'g0',1))\n"
                         " elif os.environ.get('LOWERING_TEST_MUTATION') == 'worker-failure':\n"
                         "  sys.exit(23)\n"
                         " elif os.environ.get('LOWERING_TEST_MUTATION') == 'import':\n"
                         f"  p=Path({str(project / 'm0.vibe')!r})\n"
                         "  p.write_text(p.read_text().replace('{ 0 }', '{ 9 }'))\n"
                         " else:\n"
                         f"  p=Path({str(project / 'main.vibe')!r})\n"
                         "  p.write_text(p.read_text().replace('f0() +', '100 +'))\n"
                         f"sys.exit(subprocess.run([{str(runner)!r},*sys.argv[1:]]).returncode)\n")
        proxy.chmod(0o755)
        altered = project / "images"
        shutil.copytree(artifacts, altered, ignore=shutil.ignore_patterns("compile-cache"))
        receipt = json.loads((altered / "build.json").read_text())
        receipt["runner_sha256"] = hashlib.sha256(proxy.read_bytes()).hexdigest()
        (altered / "build.json").write_text(json.dumps(receipt))
        target = project / "changed.wasm"
        target.write_bytes(b"keep previous output")
        output, trace, result = build("changed", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_RUNNER": str(proxy),
             "VIBE_LOWERING_ARTIFACT_DIR": str(altered)}, expected=1)
        assert output.read_bytes() == b"keep previous output" and not trace.exists(), result
        assert "inputs changed after preparation" in result.stderr, result
        (project / "main.vibe").write_text(source)
        output, trace, result = build("tampered-job", ["--jobs", "2"],
            {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_RUNNER": str(proxy),
             "VIBE_LOWERING_ARTIFACT_DIR": str(altered), "LOWERING_TEST_MUTATION": "job"}, expected=1)
        assert not output.exists() and not trace.exists(), result
        assert "product does not match its prepared input" in result.stderr, result
        for mutation, message in [("import", "inputs changed after preparation"),
                                  ("worker-failure", "coordinator exited 23")]:
            label = f"refuse-{mutation}"
            target = project / f"{label}.wasm"
            target.write_bytes(b"keep previous output")
            output, trace, result = build(label, ["--jobs", "2"],
                {"VIBE_TASKGROUP_LOWERING": "1", "VIBE_RUNNER": str(proxy),
                 "VIBE_LOWERING_ARTIFACT_DIR": str(altered), "LOWERING_TEST_MUTATION": mutation}, expected=1)
            assert output.read_bytes() == b"keep previous output" and not trace.exists(), result
            assert message in result.stderr, result
            (project / "m0.vibe").write_bytes(previous)
    print("TaskGroup lowering: public CLI parity 1/2/4, bounded waves, input freshness, trace aliases and protected output passed")


if __name__ == "__main__":
    main()

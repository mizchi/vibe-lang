#!/usr/bin/env python3
"""Linux measurement driver for #3481; never changes the ordinary build route.

Prepare a frozen source archive, measure real bootstrap scripts, then measure
the separately supported function-worker corpus. Profiles are separate runs.
Run with --help for the commands; raw output is retained in the workspace.
"""
import argparse
import difflib
import hashlib
import json
import os
import platform
import resource
import shutil
import signal
import subprocess
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def clean_env(corpus):
    env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_")}
    env.update(VIBE_LIB=str(corpus / "lib"), VIBE_PREOPEN_DIR=str(corpus),
               VIBE_UNSTABLE="1", VIBE_CHECKED_MODULE_CACHE="off",
               VIBE_CODEGEN_BODY_CACHE="off", VIBE_DISABLE_PERSISTENT_ARTIFACT_CACHE="1",
               VIBE_IMPORT_ABI="raw")
    return env


def freeze(workspace, ref):
    corpus = workspace / "corpus"
    if not corpus.exists():
        workspace.mkdir(parents=True)
        corpus.mkdir()
        with (workspace / "source.tar").open("wb") as output:
            subprocess.run(["git", "archive", ref], cwd=REPO, stdout=output, check=True)
        with tarfile.open(workspace / "source.tar") as archive:
            archive.extractall(corpus, filter="data")
        (corpus / "bootstrap/seed").mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / "bootstrap/seed/compiler.wasm", corpus / "bootstrap/seed/compiler.wasm")
    if (workspace / "workspace.json").exists():
        raise ValueError("workspace already prepared; retain its measurements")
    tracked = {}
    with tarfile.open(workspace / "source.tar") as archive:
        for member in archive:
            if member.isfile():
                tracked[member.name] = {"sha256": hashlib.sha256(archive.extractfile(member).read()).hexdigest()}
            elif member.issym():
                tracked[member.name] = {"symlink": member.linkname}
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=REPO, text=True).strip()
    # An existing pilot workspace can be adopted only if its archive really is
    # the selected commit, rather than relabelling whatever files are present.
    expected = subprocess.check_output(["git", "archive", ref], cwd=REPO)
    if hashlib.sha256(expected).hexdigest() != sha(workspace / "source.tar"):
        raise ValueError("archive differs from selected source commit")
    seed = json.loads((corpus / "bootstrap/seed.json").read_text())["seed"]
    if sha(corpus / "bootstrap/seed/compiler.wasm") != seed["artifact"]["sha256"]:
        raise ValueError("seed differs from pin")
    meta = {"source_commit": git("rev-parse", ref), "source_tree": git("rev-parse", ref + "^{tree}"),
            "archive_sha256": sha(workspace / "source.tar"), "tracked_files": tracked,
            "seed": seed, "machine": {"kernel": platform.release(), "cpus": os.cpu_count(),
            "cpu": next(l.split(":", 1)[1].strip() for l in Path("/proc/cpuinfo").read_text().splitlines() if l.startswith("model name")),
            "memory_bytes": os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"),
            "node": subprocess.check_output(["node", "--version"], text=True).strip()},
            "harness_sha256": sha(__file__)}
    verify_source(corpus, meta)
    write(workspace / "workspace.json", meta)


def verify_source(corpus, meta):
    if "archive_sha256" in meta and sha(corpus.parent / "source.tar") != meta["archive_sha256"]:
        raise ValueError("frozen source archive changed")
    for name, receipt in meta["tracked_files"].items():
        path = corpus / name
        if "symlink" in receipt:
            if not path.is_symlink() or os.readlink(path) != receipt["symlink"]:
                raise ValueError("source symlink changed: " + name)
        elif not path.is_file() or sha(path) != receipt["sha256"]:
            raise ValueError("frozen source changed: " + name)
    if sha(corpus / "bootstrap/seed/compiler.wasm") != meta["seed"]["artifact"]["sha256"]:
        raise ValueError("frozen seed changed")


def monotonic_spans(workspace):
    """Apply only the reviewed host-clock instrumentation to the frozen tree."""
    path = "scripts/trace_lib.sh"
    corpus = workspace / "corpus"
    meta = json.loads((workspace / "workspace.json").read_text())
    verify_source(corpus, meta)
    if "host_instrumentation" in meta:
        raise ValueError("host instrumentation already recorded")
    original = (corpus / path).read_text()
    updated = (REPO / path).read_text()
    if "VIBE_TRACE_MONOTONIC" not in updated:
        raise ValueError("expected the explicit monotonic-clock helper")
    patch = "".join(difflib.unified_diff(original.splitlines(True), updated.splitlines(True), fromfile=path, tofile=path))
    (workspace / "host-clock.patch").write_text(patch)
    before = sha(corpus / path)
    shutil.copy2(REPO / path, corpus / path)
    after = sha(corpus / path)
    meta["host_instrumentation"] = {"path": path, "original_sha256": before, "measured_sha256": after,
                                    "patch_sha256": sha(workspace / "host-clock.patch"),
                                    "scope": "Opt-in same-host monotonic spans; compiler/seed/build decisions remain the archived source."}
    meta["tracked_files"][path] = {"sha256": after}
    write(workspace / "workspace.json", meta)
    verify_source(corpus, meta)


def snapshot(root):
    stats = {}
    for path in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = path.read_text().rsplit(")", 1)[1].split()
            stats[int(path.parent.name)] = (int(fields[1]), int(fields[21]) * os.sysconf("SC_PAGE_SIZE"),
                                           (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK"))
        except (OSError, ValueError, IndexError):
            continue
    owned = {root}
    while True:
        more = {pid for pid, (parent, _, _) in stats.items() if parent in owned}
        if more <= owned:
            break
        owned |= more
    return {pid: stats[pid] for pid in owned if pid in stats}


def measure(command, corpus, env, directory, timeout=1200):
    directory.mkdir()
    start = time.monotonic()
    realtime_start = time.time_ns()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    peaks = {"process_tree_peak_rss_bytes": 0, "process_tree_peak_processes": 0}
    processes = {}
    with (directory / "run.log").open("w") as log:
        child = subprocess.Popen(command, cwd=corpus, env=env, stdout=log, stderr=log, start_new_session=True)
        write(directory / "live.json", {"pid": child.pid, "command": command})
        try:
            while child.poll() is None:
                current = snapshot(child.pid)
                peaks["process_tree_peak_rss_bytes"] = max(peaks["process_tree_peak_rss_bytes"], sum(v[1] for v in current.values()))
                peaks["process_tree_peak_processes"] = max(peaks["process_tree_peak_processes"], len(current))
                for pid, (_, rss, cpu) in current.items():
                    try:
                        cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
                    except OSError:
                        continue
                    key = f"{pid}:{cmd}"
                    row = processes.setdefault(key, {"pid": pid, "command": cmd, "first_seen_s": time.monotonic() - start, "peak_rss_bytes": 0})
                    row.update(last_seen_s=time.monotonic() - start, cpu_s_last_seen=cpu)
                    row["peak_rss_bytes"] = max(row["peak_rss_bytes"], rss)
                if time.monotonic() - start > timeout:
                    raise TimeoutError("measurement exceeded bound; see " + str(directory))
                time.sleep(.02)
        except BaseException:
            # The public worker frontend owns a separate process group and
            # forwards TERM to it. Give it time to join/reap before escalation.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    result = {"command": command, "returncode": child.returncode, "wall_s": time.monotonic() - start,
              "realtime_elapsed_s": (time.time_ns() - realtime_start) / 1e9,
              "user_cpu_s": after.ru_utime - before.ru_utime, "system_cpu_s": after.ru_stime - before.ru_stime,
              **peaks, "processes": list(processes.values())}
    write(directory / "processes.json", result)
    if child.returncode:
        raise RuntimeError("measurement failed; inspect " + str(directory / "run.log"))
    return {k: v for k, v in result.items() if k != "processes"}


def fixed_point(generation):
    manifest = json.loads((generation / "generation.json").read_text())
    if not manifest["result"]["stage3_equal_stage2"]:
        raise ValueError("generation did not prove stage2 == stage3")
    for stage in ["stage0", "stage1", "stage2", "stage3"]:
        path = generation / ("stage0_seed.wasm" if stage == "stage0" else stage + ".wasm")
        if sha(path) != manifest["stages"][stage]["sha256"]:
            raise ValueError("generation artifact differs: " + stage)
    if (generation / "stage2.wasm").read_bytes() != (generation / "stage3.wasm").read_bytes():
        raise ValueError("stage2 and stage3 bytes differ")
    return manifest


def bootstrap(workspace, rounds):
    corpus = workspace / "corpus"
    meta = json.loads((workspace / "workspace.json").read_text())
    verify_source(corpus, meta)
    if "host_instrumentation" not in meta:
        raise ValueError("record monotonic host spans with the clock command first")
    out = workspace / "bootstrap"
    out.mkdir()
    samples = []
    report = {"source_commit": meta["source_commit"], "machine": meta["machine"], "samples": samples,
              "host_instrumentation": meta["host_instrumentation"], "harness_sha256": sha(__file__),
              "protocol": "Serial; compiler then portable CLI, reversed in alternate rounds. Cold removes only this isolated checkout's merge-tool image/stamp and starts a fresh guest cache; warm reuses both. Outputs are always regenerated. Node processes/JIT are fresh; OS page cache is warm. Packaging, installation and native runner compilation are excluded. Host spans and end-of-run memory counters are enabled; no CPU profiling.",
              "memory": "Simultaneous process-tree RSS sampled every20ms; shared pages can be double-counted. Per-process first/last observations are bounds, not exact lifetimes. Guest bump frontier/allocation/committed memory are retained in logs, not inferred from RSS."}
    expected = {}
    for rnd in range(rounds):
        for subject in (["compiler", "portable-cli"] if rnd % 2 == 0 else ["portable-cli", "compiler"]):
            private = out / f"{rnd}-{subject}"
            private.mkdir()
            for temperature in ["cold", "warm"]:
                if temperature == "cold":
                    for suffix in ["", ".fingerprint"]:
                        (corpus / ("_build/merge_flatten_compiler.wasm" + suffix)).unlink(missing_ok=True)
                env = clean_env(corpus) | {"VIBE_BUILD_CACHE_DIR": str(private / "cache"), "VIBE_MEM": "1", "VIBE_TRACE_MONOTONIC": "1",
                        "VIBE_WASM_MEMORY_STATS": "1", "VIBE_BUILD_CLI_WASM_NO_CACHE": "1"}
                run = private / temperature
                env["VIBE_TRACE_OUT"] = str(run / "spans.ndjson")
                generation = corpus / "_build/measured-generation"
                if subject == "compiler":
                    command = ["bash", "scripts/generations.sh", "build", "--stage3", "--out-dir", str(generation)]
                else:
                    command = ["bash", "scripts/build_cli_wasm.sh", "_build/measured-cli.wasm"]
                result = measure(["bash", "scripts/trace_span.sh", subject, *command], corpus, env, run)
                spans = [json.loads(line) for line in (run / "spans.ndjson").read_text().splitlines()]
                if not spans or any(s.get("clock") != "monotonic" or s["t1"] < s["t0"] or s["rc"] != 0 for s in spans):
                    raise ValueError("missing, incompatible or failed host spans")
                result["spans"] = spans
                if subject == "compiler":
                    receipt = fixed_point(generation)
                    digest = receipt["stages"]["stage2"]["sha256"]
                else:
                    digest = sha(corpus / "_build/measured-cli.wasm")
                    manifests = list((corpus / "_build/selfhost/generations").glob("*/generation.json"))
                    if len(manifests) != 1:
                        raise ValueError("portable CLI did not select one explicit generation")
                    receipt = json.loads(manifests[0].read_text())
                    if receipt["stages"]["stage2"]["sha256"] != digest:
                        raise ValueError("portable CLI publication differs from producer")
                if expected.setdefault(subject, digest) != digest:
                    raise ValueError("bootstrap output changed across configurations")
                write(run / "generation.json", receipt)
                bundle_log = generation / "selfhost_bundle_generation.log" if subject == "compiler" else manifests[0].parent / "selfhost_bundle_generation.log"
                shutil.copy2(bundle_log, run / "bundle.log")
                if temperature == "cold":
                    for suffix in ["", ".seedflat", ".flatten"]:
                        source = corpus / ("_build/merge_flatten_compiler.log" + suffix)
                        shutil.copy2(source, run / ("seed-tool.log" + suffix))
                result.update(subject=subject, round=rnd, temperature=temperature, artifact_sha256=digest,
                              raw_directory=str(run.relative_to(workspace)))
                samples.append(result)
                write(out / "measurement.json", report)
                print(subject, rnd, temperature, f"{result['wall_s']:.3f}s", f"{result['process_tree_peak_rss_bytes']/2**20:.1f}MiB", flush=True)
    verify_source(corpus, meta)
    if report["harness_sha256"] != sha(__file__) or len(samples) != rounds * 4:
        raise ValueError("harness changed or bootstrap samples are incomplete")
    report["verified_complete"] = True
    report["artifacts"] = expected
    write(out / "measurement.json", report)


def images(workspace):
    corpus = workspace / "corpus"
    meta = json.loads((workspace / "workspace.json").read_text())
    verify_source(corpus, meta)
    generation = corpus / "_build/measured-generation"
    receipt = fixed_point(generation)
    env = clean_env(corpus)
    # Reuse only a runner whose maintained source stamp is current in BOTH
    # trees. This is preparation, outside all measured intervals.
    subprocess.run(["bash", "scripts/ensure_viberun.sh", "--check"], cwd=REPO, env=env, check=True)
    for name in meta["tracked_files"]:
        if name.startswith("runtime/viberun/") and sha(REPO / name) != sha(corpus / name):
            raise ValueError("current runner sources differ from frozen source: " + name)
    target = corpus / "runtime/viberun/target/release"
    target.mkdir(parents=True, exist_ok=True)
    for name in ["viberun", ".viberun_srchash"]:
        shutil.copy2(REPO / "runtime/viberun/target/release" / name, target / name)
    subprocess.run(["bash", "scripts/ensure_viberun.sh", "--check"], cwd=corpus, env=env, check=True)
    subprocess.run(["bash", "scripts/ensure_generated.sh"], cwd=corpus, env=env, check=True)
    out = workspace / "engines"
    out.mkdir()
    for key in ["o0", "a0"]:
        lane = out / key
        lane.mkdir()
        shutil.copy2(generation / "stage2.wasm", lane / "compiler.wasm")
        shutil.copy2(target / "viberun", lane / "viberun")
    subprocess.run(["bash", "scripts/build_taskgroup_functions.sh", str(out / "o0/compiler.wasm"), str(out / "images")],
                   cwd=corpus, env=env, check=True)
    write(out / "compiler-generation.json", receipt)
    verify_source(corpus, meta)


def image_receipts(workspace):
    engines = workspace / "engines"
    receipt = json.loads((engines / "images/build.json").read_text())
    producer = json.loads((engines / "compiler-generation.json").read_text())
    bootstrap_report = json.loads((workspace / "bootstrap/measurement.json").read_text())
    measured = bootstrap_report.get("artifacts", {}).get("compiler")
    if (not bootstrap_report.get("verified_complete") or not producer["result"]["stage3_equal_stage2"]
            or producer["stages"]["stage2"]["sha256"] != measured
            or producer["stages"]["stage3"]["sha256"] != measured
            or receipt["compiler_sha256"] != measured):
        raise ValueError("images do not belong to the completed measured producer")
    if receipt["kind"] != "vibe-taskgroup-functions" or receipt["compiler_sha256"] != sha(engines / "o0/compiler.wasm"):
        raise ValueError("worker images belong to another compiler")
    if receipt["runner_sha256"] != sha(engines / "o0/viberun"):
        raise ValueError("worker images belong to another runner")
    if sha(engines / "o0/compiler.wasm") != sha(engines / "a0/compiler.wasm") or sha(engines / "o0/viberun") != sha(engines / "a0/viberun"):
        raise ValueError("A/A controls are different artifacts")
    for name, digest in receipt["artifacts"].items():
        if sha(engines / "images" / name) != digest:
            raise ValueError("worker image changed: " + name)
    return receipt


def guest_memory(log):
    lines = [line for line in log.splitlines() if line.startswith("vibe::mem ")]
    if not lines:
        raise ValueError("missing guest memory counters")
    fields = {}
    for field in lines[-1].split()[1:]:
        key, separator, value = field.partition("=")
        if separator and value.isdigit():
            fields[key] = int(value)
    required = ["heap_base", "heap_peak", "allocated", "committed"]
    if any(key not in fields for key in required):
        raise ValueError("incomplete guest memory counters")
    if (fields["heap_peak"] < fields["heap_base"] or fields["committed"] < fields["heap_peak"]
            or fields["allocated"] != fields["heap_peak"] - fields["heap_base"]
            or fields["committed"] % 65536):
        raise ValueError("inconsistent guest memory counters")
    return {**{key: fields[key] for key in required}, "pages": fields["committed"] // 65536}


def matrix_command(workspace, variant, source, destination, entry, cache, trace):
    corpus = workspace / "corpus"
    engines = workspace / "engines"
    env = clean_env(corpus) | {"VIBE_RC": "1", "VIBE_FS_COMPILE": "1", "VIBE_MEM": "1",
          "VIBE_BUILD_CACHE_DIR": str(cache), "VIBE_NATIVE_CACHE_DIR": str(workspace / "native-cache")}
    if variant in ["o0", "a0"]:
        command = [str(engines / variant / "viberun"), str(engines / variant / "compiler.wasm"), source, str(destination), entry]
    elif variant == "s0":
        command = [str(engines / "o0/viberun"), str(engines / "images/compile.wasm")]
        env.update(VIBE_LOWERING_MODE="serial", VIBE_LOWERING_INPUT=source,
                   VIBE_LOWERING_OUTPUT=str(destination), VIBE_LOWERING_ENTRY=entry)
    else:
        command = ["node", str(corpus / "scripts/taskgroup_functions_frontend.mjs"), str(engines / "o0/compiler.wasm"),
                   source, str(destination), entry, variant[1], str(corpus), str(engines / "images"), str(engines / "o0/viberun")]
        env["VIBE_FUNCTION_TRACE_OUT"] = str(trace)
    return command, env


def matrix(workspace, rounds):
    corpus = workspace / "corpus"
    meta = json.loads((workspace / "workspace.json").read_text())
    verify_source(corpus, meta)
    receipt = image_receipts(workspace)
    out = workspace / "matrix"
    out.mkdir()
    # This includes the generated library inputs as well as maintained source.
    inputs = {str(p.relative_to(corpus)): sha(p) for p in sorted((corpus / "lib").rglob("*")) if p.is_file()}
    (corpus / "perf-smoke.vibe").write_text("fn main() -> Int { 7 - 3 }\n")
    variants = ["o0", "a0", "s0", "p1", "p2", "p4"]
    for variant in variants[:4]:
        command, env = matrix_command(workspace, variant, "perf-smoke.vibe", out / f"prime-{variant}.wasm",
                                      "main", out / f"prime-{variant}-cache", out / f"prime-{variant}.json")
        measure(command, corpus, env, out / f"prime-{variant}")
    samples = []
    report = {"source_commit": meta["source_commit"], "receipts": receipt, "input_sha256": inputs, "harness_sha256": sha(__file__),
              "machine": meta["machine"], "samples": samples,
              "protocol": "Native JIT primed on a different input; fresh guest cache per round/variant, cold followed by warm in new processes. Forward/reverse/forward order; equal-length lane and cache paths. o0/a0 are A/A controls; s0 is the same-driver serial reference; p1/p2/p4 are whole public native frontend builds. Target RC1; parent/worker engines bump, coordinator RC. Checked-module/body/final-artifact caches off. RSS sampled every20ms; shared mappings may be double-counted. No concurrent builds/profiles."}
    expected = {}
    for subject, prefix, source, entry in [
        ("compiler", "c", "lib/@vibe/compiler/tests/codegen_lexer_test.vibe", "__no_entry__"),
        ("split-cli", "l", "lib/@vibe/cli/entry.vibe", "cli_main")]:
        for rnd in range(rounds):
            for variant in (variants if rnd % 2 == 0 else list(reversed(variants))):
                private = out / f"{prefix}{rnd}-{variant}"
                private.mkdir()
                for temperature in ["cold", "warm"]:
                    destination = private / "out.wasm"
                    destination.unlink(missing_ok=True)
                    trace = private / f"{temperature}.json"
                    command, env = matrix_command(workspace, variant, source, destination, entry, private / "cache", trace)
                    result = measure(command, corpus, env, private / temperature)
                    if variant in ["o0", "a0", "s0"]:
                        result["guest_memory"] = guest_memory((private / temperature / "run.log").read_text())
                    else:
                        result["guest_memory"] = None
                        result["memory_scope"] = "Aggregate RSS is measured here; per-worker guest counters require separate diagnostic replays."
                    digest = sha(destination)
                    if expected.setdefault(subject, digest) != digest:
                        raise ValueError("whole-build output differs across routes: " + subject)
                    if trace.exists():
                        result["phases"] = json.loads(trace.read_text())
                    result.update(subject=subject, round=rnd, variant=variant, temperature=temperature,
                                  artifact_sha256=digest, raw_directory=str((private / temperature).relative_to(workspace)))
                    samples.append(result)
                    write(out / "measurement.json", report)
                    print(subject, rnd, variant, temperature, f"{result['wall_s']:.3f}s", f"{result['process_tree_peak_rss_bytes']/2**20:.1f}MiB", flush=True)
    for subject in ["compiler", "split-cli"]:
        for rnd in range(rounds):
            for temperature in ["cold", "warm"]:
                controls = [row for row in samples if row["subject"] == subject and row["round"] == rnd
                            and row["temperature"] == temperature and row["variant"] in ["o0", "a0"]]
                if len(controls) != 2 or controls[0]["guest_memory"] != controls[1]["guest_memory"]:
                    raise ValueError("A/A guest heap or reserved pages differ")
    verify_source(corpus, meta)
    if receipt != image_receipts(workspace) or any(sha(corpus / name) != digest for name, digest in inputs.items()) or report["harness_sha256"] != sha(__file__):
        raise ValueError("matrix inputs or images changed")
    report.update(verified_complete=True, artifacts=expected, aa_guest_memory_exact=True)
    write(out / "measurement.json", report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "clock", "bootstrap", "images", "matrix"])
    parser.add_argument("workspace", type=Path)
    parser.add_argument("--ref", default="HEAD")
    parser.add_argument("--rounds", type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 3:
        parser.error("at least three rounds are required")
    if args.command == "prepare":
        freeze(args.workspace.resolve(), args.ref)
    elif args.command == "clock":
        monotonic_spans(args.workspace.resolve())
    elif args.command == "bootstrap":
        bootstrap(args.workspace.resolve(), args.rounds)
    elif args.command == "images":
        images(args.workspace.resolve())
    else:
        matrix(args.workspace.resolve(), args.rounds)


if __name__ == "__main__":
    main()

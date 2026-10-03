"""Real WIT batch requests: serial products, bounded workers and trap cleanup.

Functional Linux oracle; overlapping CPU progress is covered by the companion
checker_taskgroup_worker_test.py. Neither script establishes a speedup.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
for name in ["compiler", "runner", "worker", "coordinator"]:
    parser.add_argument("--" + name, type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = Path(tempfile.mkdtemp(prefix="checker-batches-", dir=root / "_build"))
compiler, runner, worker, coordinator = [
    getattr(args, name).resolve() for name in ["compiler", "runner", "worker", "coordinator"]
]
assert all(path.is_file() for path in [compiler, runner, worker, coordinator])
base = {key: value for key, value in os.environ.items() if not key.startswith("VIBE_")}
base["VIBE_NATIVE_CACHE_DIR"] = str(out / "native-cache")


def prepare(name, count, *, bad=False, slow=False, cfg=False):
    jobs = []
    for i in range(count):
        job = out / f"{name}-{i}"
        job.mkdir()
        manifest = f"version\t1\npath\t{out}/source-{i}.vibe\n"
        if bad:
            mutated = manifest.replace("version\t1\n", "version\t999\n")
            assert mutated != manifest and "version\t999\n" in mutated
            manifest = mutated
        source = (
            f"fn double_id(x: Double) -> Double {{ x }}\n"
            f"export fn main() -> Double {{ double_id({i}.5) }}\n"
        )
        if name == "mixed" and i == 7:
            source = 'export fn failure() -> Int { throw("failure") }\n'
        if cfg:
            source += '#cfg(dev)\nexport fn selected() -> Int { 1 }\n'
            source += '#cfg(release)\nexport fn selected() -> String { "release" }\n'
        if slow:
            source += "\n".join(f"fn f{k}(x: Int) -> Int {{ x + {k} }}" for k in range(3000))
        (job / "job.txt").write_text(manifest)
        (job / "source.vibe").write_text(source)
        jobs.append(str(job))
    return jobs


def invoke(name, queues, environment=None, *, plan_version=1):
    plan = out / f"{name}.json"
    plan.write_text(json.dumps({"version": plan_version, "wasm": str(worker),
                                "cwd": str(root), "queues": queues}))
    result = subprocess.run([str(runner), str(coordinator)], cwd=root,
                            env={**base, **(environment or {}), "VIBE_CHECKER_WORKERS": str(plan),
                                 "VIBE_CHECKER_WORKER_TRACE": "1", "VIBE_CHECKER_WORKER_MEM": "1"},
                            capture_output=True, timeout=120)
    log = result.stderr.decode()
    (out / f"{name}.stderr").write_text(log)
    (out / f"{name}.stdout").write_bytes(result.stdout)
    events = [json.loads(line.split(" ", 1)[1]) for line in log.splitlines()
              if line.startswith("vibe-checker-worker ")]
    started = [event for event in events if event["event"] == "started"]
    live = set()
    maximum = 0
    for event in events:
        if event["event"] == "started":
            assert event["slot"] not in live, ("overlapping requests on a slot", events)
            live.add(event["slot"])
            maximum = max(maximum, len(live))
        else:
            live.discard(event["slot"])
    for event in started:
        assert not Path(f'/proc/{event["pid"]}').exists(), ("worker not reaped", event)
    return result, events, maximum


def compare(jobs, environment=None):
    for name in jobs:
        job = Path(name)
        control = out / ("serial-" + job.name)
        control.mkdir()
        for file in ["job.txt", "source.vibe"]:
            shutil.copy2(job / file, control / file)
        result = subprocess.run([str(runner), str(compiler), str(control),
                                 str(control / "worker.out"), "__no_entry__"], cwd=root,
                                env={**base, **(environment or {}), "VIBE_MODULE_JOB_DIR": "1",
                                     "VIBE_IMPORT_ABI": "raw"}, capture_output=True, timeout=30)
        assert result.returncode == 0, result.stderr.decode()
        for file in ["outcome.txt", "env.out", "cache.out", "diag.txt", "fingerprint.out"]:
            actual = (job / file).read_bytes() if (job / file).exists() else None
            expected = (control / file).read_bytes() if (control / file).exists() else None
            assert actual == expected, (job.name, file)


rows = []
# More than one batch on a slot; a diagnostic in the middle must neither stop
# the other checks nor become an invented successful environment.
for name, count, settings in [("mixed", 17, {}), ("cfg", 17, {"VIBE_CFG": " dev ,, "})]:
    jobs = prepare(name, count, cfg=name == "cfg")
    result, events, maximum = invoke(name, [jobs, [], [], []], settings)
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout.strip() == (b"1" if name == "mixed" else b"0")
    finished = [event for event in events if event["event"] == "finished"]
    assert len(finished) == 2 and maximum == 1, events
    assert all(event["status"] == 0 and event["memory"]["allocated"] > 0 for event in finished)
    compare(jobs, settings)
    rows.append({"case": name, "jobs": count, "fresh_processes": 2,
                 "products_match_serial": True, "all_workers_reaped": True})
    print(name, "two bounded batches match serial products", flush=True)

queues = [prepare("parallel-" + str(slot), 2) for slot in range(4)]
result, events, maximum = invoke("parallel", queues)
assert result.returncode == 0 and result.stdout.strip() == b"0", result.stderr.decode()
assert maximum == 4, events
for queue in queues:
    compare(queue)
rows.append({"case": "parallel", "jobs": 8, "max_owned_children": maximum,
             "products_match_serial": True, "all_workers_reaped": True})
print("four slots complete real checks and reap workers", flush=True)

# Corrupt the actual input, fail in the host WIT call, and force TaskGroup's
# pending sibling through Drop. Its large real check cannot commit first.
slow = prepare("cancelled", 1, slow=True)
bad = prepare("bad-version", 1, bad=True)
result, events, maximum = invoke("failure", [slow, bad, [], []])
assert result.returncode == 1, result.stderr.decode()
assert b"batch exited" in result.stderr and b"999" in result.stderr, result.stderr.decode()
assert len([event for event in events if event["event"] == "started"]) == 2, events
assert any(event["event"] in ["cancelled", "dropped"] for event in events), events
assert not (Path(slow[0]) / "outcome.txt").exists(), "cancelled check committed a product"
rows.append({"case": "failure", "child_error_preserved": True, "sibling_cancelled": True,
             "all_workers_reaped": True})
print("WIT failure preserves child error and cancels/reaps sibling", flush=True)

unused = prepare("invalid-plan", 1)
result, events, _ = invoke("invalid-plan", [unused, [], [], []], plan_version=2)
assert result.returncode == 1 and b"expected version 1" in result.stderr and not events
(out / "results.json").write_text(json.dumps({"status": "passed", "rows": rows,
                                               "invalid_plan_rejected_before_spawn": True}, indent=2) + "\n")
print("retained WIT batch oracle:", out, flush=True)

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
parser.add_argument("--backend", choices=["process", "thread"], default="process")
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
base["VIBE_CHECKER_WORKER_BACKEND"] = args.backend
threaded = args.backend == "thread"


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
            f"fn double_id(x: Float64) -> Float64 {{ x }}\n"
            f"export fn main() -> Float64 {{ double_id(x = {i}.5) }}\n"
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


def write_plan(name, queues, *, plan_version=1):
    plan = out / f"{name}.json"
    plan.write_text(json.dumps({"version": plan_version, "wasm": str(worker),
                                "cwd": str(root), "queues": queues}))
    return plan


def invoke(name, queues, environment=None, *, plan_version=1):
    plan = write_plan(name, queues, plan_version=plan_version)
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
    rows.append({"case": name, "jobs": count, "fresh_batches": 2,
                 "products_match_serial": True, "all_workers_reaped": True})
    print(name, "two bounded batches match serial products", flush=True)

for count in ([2, 4] if threaded else [4]):
    queues = [prepare(f"parallel-{count}-{slot}", 2, slow=threaded) for slot in range(count)]
    result, events, maximum = invoke(f"parallel-{count}", queues + [[] for _ in range(4 - count)])
    assert result.returncode == 0 and result.stdout.strip() == b"0", result.stderr.decode()
    assert maximum == count, events
    for queue in queues:
        compare(queue)
    if threaded:
        started = {event["thread"]: event for event in events if event["event"] == "started"}
        finished = {event["thread"]: event for event in events if event["event"] == "finished"}
        assert len(started) == len(finished) == count, events
        assert started.keys() == finished.keys()
        assert len({event["pid"] for event in events}) == 1, events
        assert max(event["at_us"] for event in started.values()) < min(event["at_us"] for event in finished.values()), events
        assert all(finished[tid]["cpu_ticks"] > event["cpu_ticks"] for tid, event in started.items()), events
    rows.append({"case": f"parallel-{count}", "jobs": count * 2, "max_owned_batches": maximum,
                 "products_match_serial": True, "all_workers_reaped": True})
    print(count, "slots complete real checks and reap workers", flush=True)

# Corrupt the actual input, fail in the host WIT call, and force TaskGroup's
# pending sibling through Drop. Its large real check cannot commit first.
slow = prepare("cancelled", 1, slow=True)
bad = prepare("bad-version", 1, bad=True)
result, events, maximum = invoke("failure", [slow, bad, [], []])
assert result.returncode == 1, result.stderr.decode()
message = b"threaded batch failed" if threaded else b"batch exited"
assert message in result.stderr and b"999" in result.stderr, result.stderr.decode()
assert len([event for event in events if event["event"] == "started"]) == 2, events
assert any(event["event"] in ["cancelled", "dropped"] for event in events), events
assert not (Path(slow[0]) / "outcome.txt").exists(), "cancelled check committed a product"
rows.append({"case": "failure", "child_error_preserved": True, "sibling_cancelled": True,
             "all_workers_reaped": True})
print("WIT failure preserves child error and cancels/reaps sibling", flush=True)

unused = prepare("invalid-plan", 1)
result, events, _ = invoke("invalid-plan", [unused, [], [], []], plan_version=2)
assert result.returncode == 1 and b"expected version 1" in result.stderr and not events

if threaded:
    first, second = prepare("session-first", 1), prepare("session-second", 2)
    slow = prepare("session-cancelled", 1, slow=True)
    bad = prepare("session-bad-version", 1, bad=True)
    unused = prepare("session-after-failure", 1)
    plans = [
        write_plan("session-first", [first, [], [], []]),
        write_plan("session-second", [[], second, [], []]),
        write_plan("session-failure", [slow, bad, [], []]),
        write_plan("session-after-failure", [unused, [], [], []]),
    ]
    result = subprocess.run(
        [str(runner), "--checker-session", str(coordinator), str(worker)], cwd=root, env=base,
        input="".join(json.dumps(str(plan)) + "\n" for plan in plans),
        text=True, capture_output=True, timeout=120,
    )
    assert result.returncode == 1 and "999" in result.stderr, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == 2 and all(reply["diagnosed"] == 0 for reply in replies), replies
    for slot, reply in enumerate(replies):
        assert [(event["event"], event["slot"]) for event in reply["events"]] == [
            ("started", slot), ("finished", slot),
        ], reply
    assert len({event["pid"] for reply in replies for event in reply["events"]}) == 1, replies
    failed = [json.loads(line.split(" ", 1)[1]) for line in result.stderr.splitlines()
              if line.startswith("vibe-checker-worker ")]
    assert any(event["event"] == "cancelled" and event["slot"] == 0 for event in failed), failed
    assert all(not (Path(job) / "outcome.txt").exists() for job in slow + unused)
    compare(first + second)
    rows.append({"case": "session", "successful_waves": 2, "stops_after_failed_wave": True})
    print("checker session reuses its process and stops after a failed wave", flush=True)
    slow = prepare("ready-cancelled", 1, slow=True)
    bad = prepare("ready-bad-version", 1, bad=True)
    plans = [write_plan("ready-cancelled", [slow, [], [], []]),
             write_plan("ready-bad-version", [bad, [], [], []])]
    ready = subprocess.run(
        [str(runner), "--checker-ready-session", str(coordinator), str(worker), "2"],
        cwd=root, env=base, input="".join(
            json.dumps({"id": index, "manifest": str(plan)}) + "\n" for index, plan in enumerate(plans)
        ), text=True, capture_output=True, timeout=120,
    )
    assert ready.returncode == 1 and "999" in ready.stderr, (ready.stdout, ready.stderr)
    assert not ready.stdout and not (Path(slow[0]) / "outcome.txt").exists(), ready.stdout
    rows.append({"case": "ready-session", "failed_batch_cancels_active_sibling": True})
    print("ready checker session cancels an active sibling after a worker trap", flush=True)


(out / "results.json").write_text(json.dumps({"status": "passed", "backend": args.backend, "rows": rows,
                                               "invalid_plan_rejected_before_spawn": True}, indent=2) + "\n")
print("retained WIT batch oracle:", out, flush=True)

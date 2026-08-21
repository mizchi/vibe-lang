#!/usr/bin/env python3
"""Aggregate selfhost-suite coverage without conflating entry-weighted and union metrics."""

import json
import os
import re
import sys


def rate(hit, total):
    return round(hit / total * 100, 2) if total else 0.0


def coverage_path(cov_dir, entry):
    flat = re.sub(r"\.vibe$", "", entry.replace("/", "_"))
    return os.path.join(cov_dir, flat + ".json")


def read_cases(run_log, cov_dir):
    cases = []
    with open(run_log, encoding="utf-8") as lines:
        for line in lines:
            match = re.match(r"^(ok|FAIL)\s+(\S+\.vibe)", line.strip())
            if not match:
                continue
            ok, entry = match.group(1) == "ok", match.group(2)
            fn_hit = fn_total = branch_hit = branch_total = 0
            functions = {"hit": [], "missed": []}
            branch_per_fn = {}
            path = coverage_path(cov_dir, entry)
            if ok and os.path.isfile(path):
                with open(path, encoding="utf-8") as coverage_file:
                    cov = json.load(coverage_file)
                fn_hit, fn_total = cov.get("hit", 0), cov.get("total", 0)
                branch = cov.get("branch") or {}
                branch_hit, branch_total = branch.get("hit", 0), branch.get("total", 0)
                functions = {
                    "hit": cov.get("hit_fns") or [],
                    "missed": cov.get("missed_fns") or [],
                }
                branch_per_fn = branch.get("per_fn") or {}
            cases.append({
                "entry_path": entry,
                "ok": ok,
                "fn_hit": fn_hit,
                "fn_total": fn_total,
                "branch_hit": branch_hit,
                "branch_total": branch_total,
                "_functions": functions,
                "_branch_per_fn": branch_per_fn,
            })
    return cases


# Names the compiler synthesizes PER ENTRY PROGRAM rather than from an imported
# source file: the `_start` wrapper, and one `__test_<name>` / `__bench_<name>`
# per block in the entry itself.  Unlike every other id in the coverage JSON
# these carry no source qualification, so two entries that happen to spell a
# block the same lower to the SAME name -- `hashmap_test.vibe` and
# `sortedmap_test.vibe` both declare `test "empty map"`, both emit
# `__test_empty map`, and a union keyed on the name alone silently merges two
# unrelated functions (their branch counts differ: 2 vs 4).  Merging them
# undercounts the denominator and lets a branch taken in one test mark a
# different branch covered in another.
#
# Test/bench blocks are never imported, so a name in this class appearing in
# two entries is ALWAYS two distinct functions -- folding the entry in is
# unconditionally right here.  It would be wrong for anything else: plenty of
# genuinely shared ids also lack a source suffix (`Array::map`, `T::equals`),
# and splitting those per entry would inflate the denominator instead.
_ENTRY_LOCAL_PREFIXES = ("__test_", "__bench_", "_start")


def union_key(entry_path, name):
    if name.startswith(_ENTRY_LOCAL_PREFIXES):
        return f"{entry_path}::{name}"
    return name


def function_union(cases):
    # Function ids are source-qualified in coverage JSON.  A function is hit
    # if any separately-linked entry executed it; this avoids counting an
    # imported closure once for every test entry.  Entry-local synthesized
    # names are the exception -- see union_key.
    states = {}
    for case in cases:
        for name in case["_functions"]["missed"]:
            if isinstance(name, str):
                states.setdefault(union_key(case["entry_path"], name), False)
        for name in case["_functions"]["hit"]:
            if isinstance(name, str):
                states[union_key(case["entry_path"], name)] = True
    hit, total = sum(states.values()), len(states)
    return {"hit": hit, "total": total, "rate": rate(hit, total)}


def branch_union(cases):
    # #1556: the exact branch analogue of function_union.  Branch identity is
    # (owning function, ordinal within that function) -- see the `mask` note in
    # wasm_vibe_host_runner.js's dumpCoverage.  Global branch indices differ per
    # entry program and must never be compared.  The owning function is named by
    # union_key, which source-qualifies the entry-local synthesized ones so two
    # same-named test blocks in different entries stay distinct.
    #
    # `exact` is False when any passing entry reported branch data without a
    # mask (a coverage JSON produced before masks existed).  Those entries
    # still contribute their `total`, so the union stays a LOWER bound on
    # coverage rather than silently overstating it -- but the gate must not
    # ratchet on a number it cannot reproduce, so callers check the flag.
    states = {}
    exact = True
    for case in cases:
        for fn, entry in case["_branch_per_fn"].items():
            if not isinstance(entry, dict):
                continue
            key = union_key(case["entry_path"], fn)
            mask = entry.get("mask")
            total = entry.get("total", 0)
            if mask is None:
                exact = False
                mask = ""
            taken = states.get(key)
            if taken is None:
                taken = []
                states[key] = taken
            # A function's branch count can differ between entry programs when
            # the same source function is lowered differently (specialization,
            # dictionary passing).  Widen to the largest shape seen; ordinals
            # below the shared prefix still denote the same source branches.
            width = max(total, len(mask))
            if width > len(taken):
                taken.extend([False] * (width - len(taken)))
            for ordinal, char in enumerate(mask):
                if char == "1":
                    taken[ordinal] = True
    hit = sum(sum(taken) for taken in states.values())
    total = sum(len(taken) for taken in states.values())
    return {"hit": hit, "total": total, "rate": rate(hit, total), "exact": exact}, states


def branch_union_gaps(states, limit=25):
    # Which SOURCE functions still have unreached branches after unioning every
    # entry.  `top_branch_gaps` ranks entries instead, so it mostly surfaces
    # whichever entry links the largest import closure -- not where the
    # coverage actually is.  This list is what to write tests against.
    gaps = [{
        "fn": fn,
        "branch_hit": sum(taken),
        "branch_total": len(taken),
        "branch_miss": len(taken) - sum(taken),
    } for fn, taken in states.items() if sum(taken) < len(taken)]
    gaps.sort(key=lambda gap: (-gap["branch_miss"], gap["fn"]))
    return gaps[:limit]


def build_report(run_log, cov_dir):
    cases = read_cases(run_log, cov_dir)
    entries_total = len(cases)
    entries_passed = sum(case["ok"] for case in cases)
    fn_hit = sum(case["fn_hit"] for case in cases)
    fn_total = sum(case["fn_total"] for case in cases)
    branch_hit = sum(case["branch_hit"] for case in cases)
    branch_total = sum(case["branch_total"] for case in cases)
    union = function_union(cases)
    b_union, b_states = branch_union(cases)
    gaps = [{
        "entry_path": case["entry_path"],
        "branch_hit": case["branch_hit"],
        "branch_total": case["branch_total"],
        "branch_miss": case["branch_total"] - case["branch_hit"],
    } for case in cases if case["ok"] and case["branch_total"] > case["branch_hit"]]
    gaps.sort(key=lambda gap: -gap["branch_miss"])
    for case in cases:
        del case["_functions"]
        del case["_branch_per_fn"]
    return {
        "suite": "selfhost-unit-allowlist",
        "entries_total": entries_total,
        "entries_passed": entries_passed,
        "case_rate": rate(entries_passed, entries_total),
        "function_union": union,
        "branch_union": b_union,
        "entry_weighted": {
            "function": {"hit": fn_hit, "total": fn_total, "rate": rate(fn_hit, fn_total)},
            "branch": {"hit": branch_hit, "total": branch_total, "rate": rate(branch_hit, branch_total)},
        },
        "cases": cases,
        "top_branch_gaps": gaps[:10],
        "top_branch_union_gaps": branch_union_gaps(b_states),
        "top_non_aggregate_branch_gaps": [],
    }


def main(argv):
    # Union ratchets are optional so an older caller keeps working; omitting
    # them measures and prints without gating.
    run_log, cov_dir, report_path, min_point, min_line, min_branch, min_fn_hit, min_branch_hit = argv[:8]
    min_branch_union_hit, min_branch_union_rate = (argv[8:] + ["0", "0"])[:2]
    min_function_union_hit, min_function_union_rate = (argv[10:] + ["0", "0"])[:2]
    min_point, min_line, min_branch = map(float, (min_point, min_line, min_branch))
    min_fn_hit, min_branch_hit = int(min_fn_hit), int(min_branch_hit)
    min_branch_union_hit, min_branch_union_rate = int(min_branch_union_hit), float(min_branch_union_rate)
    min_function_union_hit = int(min_function_union_hit)
    min_function_union_rate = float(min_function_union_rate)
    report = build_report(run_log, cov_dir)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as output:
        json.dump(report, output, indent=2)

    weighted = report["entry_weighted"]
    function = weighted["function"]
    branch = weighted["branch"]
    union = report["function_union"]
    b_union = report["branch_union"]
    approx = "" if b_union["exact"] else " (LOWER BOUND: some entries have no branch mask)"
    print(f"[coverage-suite] cases {report['entries_passed']}/{report['entries_total']} ({report['case_rate']}%)")
    print(f"[coverage-suite] function union {union['hit']}/{union['total']} ({union['rate']}%)")
    print(f"[coverage-suite] branch union {b_union['hit']}/{b_union['total']} ({b_union['rate']}%){approx}")
    print(f"[coverage-suite] entry-weighted functions {function['hit']}/{function['total']} ({function['rate']}%)")
    print(f"[coverage-suite] entry-weighted branches {branch['hit']}/{branch['total']} ({branch['rate']}%)")
    print(f"[coverage-suite] report: {report_path}")

    failures = []
    if function["rate"] < min_point:
        failures.append(f"entry-weighted function coverage {function['rate']}% < min {min_point}% (POINT)")
    if report["case_rate"] < min_line:
        failures.append(f"case pass rate {report['case_rate']}% < min {min_line}% (LINE)")
    if branch["rate"] < min_branch:
        failures.append(f"entry-weighted branch coverage {branch['rate']}% < min {min_branch}% (BRANCH)")
    if function["hit"] < min_fn_hit:
        failures.append(f"entry-weighted covered functions {function['hit']} < min {min_fn_hit} (FN_HIT ratchet)")
    if branch["hit"] < min_branch_hit:
        failures.append(f"entry-weighted covered branches {branch['hit']} < min {min_branch_hit} (BRANCH_HIT ratchet)")
    if union["hit"] < min_function_union_hit:
        failures.append(
            f"union covered functions {union['hit']} < min {min_function_union_hit} (FUNCTION_UNION_HIT ratchet)")
    if union["rate"] < min_function_union_rate:
        failures.append(
            f"function union coverage {union['rate']}% < min {min_function_union_rate}% (FUNCTION_UNION)")
    # #1556: the branch-union floors are the metric the 60% target is stated
    # against.  Skipped when the union is only a lower bound -- gating on a
    # number the run could not measure exactly would fail for the wrong reason.
    if b_union["exact"]:
        if b_union["hit"] < min_branch_union_hit:
            failures.append(
                f"union covered branches {b_union['hit']} < min {min_branch_union_hit} (BRANCH_UNION_HIT ratchet)")
        if b_union["rate"] < min_branch_union_rate:
            failures.append(
                f"branch union coverage {b_union['rate']}% < min {min_branch_union_rate}% (BRANCH_UNION)")
    elif min_branch_union_hit or min_branch_union_rate:
        print("[coverage-suite] WARN: branch-union ratchet skipped (union is a lower bound, not exact)")
    if failures:
        for failure in failures:
            print(f"[coverage-suite] GATE FAIL: {failure}")
        return 1
    print("[coverage-suite] gate ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

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
            cases.append({
                "entry_path": entry,
                "ok": ok,
                "fn_hit": fn_hit,
                "fn_total": fn_total,
                "branch_hit": branch_hit,
                "branch_total": branch_total,
                "_functions": functions,
            })
    return cases


def function_union(cases):
    # Function ids are source-qualified in coverage JSON.  A function is hit
    # if any separately-linked entry executed it; this avoids counting an
    # imported closure once for every test entry.
    states = {}
    for case in cases:
        for name in case["_functions"]["missed"]:
            if isinstance(name, str):
                states.setdefault(name, False)
        for name in case["_functions"]["hit"]:
            if isinstance(name, str):
                states[name] = True
    hit, total = sum(states.values()), len(states)
    return {"hit": hit, "total": total, "rate": rate(hit, total)}


def build_report(run_log, cov_dir):
    cases = read_cases(run_log, cov_dir)
    entries_total = len(cases)
    entries_passed = sum(case["ok"] for case in cases)
    fn_hit = sum(case["fn_hit"] for case in cases)
    fn_total = sum(case["fn_total"] for case in cases)
    branch_hit = sum(case["branch_hit"] for case in cases)
    branch_total = sum(case["branch_total"] for case in cases)
    union = function_union(cases)
    gaps = [{
        "entry_path": case["entry_path"],
        "branch_hit": case["branch_hit"],
        "branch_total": case["branch_total"],
        "branch_miss": case["branch_total"] - case["branch_hit"],
    } for case in cases if case["ok"] and case["branch_total"] > case["branch_hit"]]
    gaps.sort(key=lambda gap: -gap["branch_miss"])
    for case in cases:
        del case["_functions"]
    return {
        "suite": "selfhost-unit-allowlist",
        "entries_total": entries_total,
        "entries_passed": entries_passed,
        "case_rate": rate(entries_passed, entries_total),
        "function_union": union,
        "entry_weighted": {
            "function": {"hit": fn_hit, "total": fn_total, "rate": rate(fn_hit, fn_total)},
            "branch": {"hit": branch_hit, "total": branch_total, "rate": rate(branch_hit, branch_total)},
        },
        "cases": cases,
        "top_branch_gaps": gaps[:10],
        "top_non_aggregate_branch_gaps": [],
    }


def main(argv):
    run_log, cov_dir, report_path, min_point, min_line, min_branch, min_fn_hit, min_branch_hit = argv
    min_point, min_line, min_branch = map(float, (min_point, min_line, min_branch))
    min_fn_hit, min_branch_hit = int(min_fn_hit), int(min_branch_hit)
    report = build_report(run_log, cov_dir)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as output:
        json.dump(report, output, indent=2)

    weighted = report["entry_weighted"]
    function = weighted["function"]
    branch = weighted["branch"]
    union = report["function_union"]
    print(f"[coverage-suite] cases {report['entries_passed']}/{report['entries_total']} ({report['case_rate']}%)")
    print(f"[coverage-suite] function union {union['hit']}/{union['total']} ({union['rate']}%)")
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
    if failures:
        for failure in failures:
            print(f"[coverage-suite] GATE FAIL: {failure}")
        return 1
    print("[coverage-suite] gate ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

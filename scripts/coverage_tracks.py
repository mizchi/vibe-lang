#!/usr/bin/env python3
"""Report both coverage tracks side by side, and ratchet each (#1556).

    coverage_tracks.py [--check]

Coverage here is TWO measurements, not one. They have different denominators
and neither subsumes the other, so a single blended number would hide exactly
the thing each is good at:

  in-process   Branches executed by the compiled TEST PROGRAMS
               (scripts/coverage_suite.sh -> branch_union).
               Answers: "what do the tests call directly?"
               Covers the stdlib and @vibex packages well. STRUCTURALLY BLIND
               to compiler passes -- a pass that runs while COMPILING a test
               lives in the (uninstrumented) stage2, so it contributes nothing
               here no matter how thoroughly fixtures exercise it.

  self-compile Branches of the COMPILER executed while it compiles a corpus of
               real programs (scripts/coverage_corpus.sh -> acc.json).
               Answers: "what does the compiler actually run on real input?"
               This is where parser/checker/codegen live. Says nothing about
               the stdlib, which it never executes -- it only emits calls.

Reading one without the other is how "cli_adapter.vibe 0/250" gets mistaken for
"untested" (it is exercised on every single compile; no test calls it
in-process). See docs/coverage.md for the control measurement.

Floors are per track and are raised as coverage improves; lowering one needs a
rationale in the PR, same convention as the other ratchets in this repo.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE = os.path.join(ROOT, "_build/coverage/selfhost-suite/selfhost_suite.report.json")
# The FINAL merged report, not acc.json -- that one is the running raw-bitmap
# accumulator the run appends to, and reading it mid-run would report a number
# the run has not finished computing.
CORPUS = os.path.join(ROOT, "_build/coverage/selfhost-corpus/merged.json")

# Env-overridable, same convention as coverage_suite.sh's floors.
#
# in-process is ratchetable as-is: its corpus IS the test suite, which only
# grows, so the rate cannot be diluted by a config knob. Measured 57.88% at
# 49d8b17 (584 entries).
MIN_IN_PROCESS_RATE = float(os.environ.get("VIBE_TRACK_MIN_IN_PROCESS_RATE", "57"))

# self-compile is NOT ratcheted by default, and a floor here would be a false
# ratchet until the corpus is pinned: the rate is a function of HOW MANY
# programs the corpus feeds the compiler. Measured on the same checkout:
#   VIBE_COV_MAX=12  ->  10,703/26,738 (40.03%)
#   (docs/coverage.md records 4,695/6,694 = 70.1% from a 626-file run, on a
#    much older and smaller compiler -- note the denominator moved 6,694 ->
#    26,738, so that number is not comparable to today's either)
# Pin the corpus (a committed file list rather than "examples + fixtures,
# capped by an env var") before setting this above 0, or the gate will pass or
# fail on how long someone was willing to wait.
MIN_SELF_COMPILE_RATE = float(os.environ.get("VIBE_TRACK_MIN_SELF_COMPILE_RATE", "0"))


def read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def pct(hit, total):
    return round(hit / total * 100, 2) if total else 0.0


def tracks():
    out = []
    suite = read(SUITE)
    if suite and isinstance(suite.get("branch_union"), dict):
        b = suite["branch_union"]
        out.append({
            "track": "in-process",
            "what": "branches the compiled test programs execute",
            "hit": b.get("hit", 0),
            "total": b.get("total", 0),
            "rate": b.get("rate", 0.0),
            "exact": b.get("exact", True),
            "source": os.path.relpath(SUITE, ROOT),
            "min_rate": MIN_IN_PROCESS_RATE,
        })
    corpus = read(CORPUS)
    if corpus and isinstance(corpus.get("branch"), dict):
        b = corpus["branch"]
        hit, total = b.get("hit", 0), b.get("total", 0)
        out.append({
            "track": "self-compile",
            "what": "compiler branches executed while compiling a corpus",
            "hit": hit,
            "total": total,
            "rate": pct(hit, total),
            "exact": True,
            "source": os.path.relpath(CORPUS, ROOT),
            "min_rate": MIN_SELF_COMPILE_RATE,
            "files": corpus.get("files"),
        })
    return out


def main(argv):
    check = "--check" in argv
    rows = tracks()
    if not rows:
        print("[coverage-tracks] neither track has a report; run 'pkf run coverage' "
              "and/or 'pkf run coverage-corpus' first", file=sys.stderr)
        return 2

    width = max(len(r["track"]) for r in rows)
    for r in rows:
        note = "" if r["exact"] else "  (LOWER BOUND)"
        print(f"[coverage-tracks] {r['track']:<{width}}  branches {r['hit']}/{r['total']} "
              f"({r['rate']}%)  min {r['min_rate']}%{note}  <- {r['what']}")
    missing = {"in-process", "self-compile"} - {r["track"] for r in rows}
    for name in sorted(missing):
        # Absence is reported, never silently treated as a pass: a track whose
        # report is stale or unbuilt is the one most likely to be regressing.
        print(f"[coverage-tracks] {name:<{width}}  NOT MEASURED in this run")

    if not check:
        return 0
    failures = []
    for r in rows:
        if not r["exact"]:
            print(f"[coverage-tracks] WARN: {r['track']} ratchet skipped (value is a lower bound)")
            continue
        if r["rate"] < r["min_rate"]:
            failures.append(f"{r['track']} branch coverage {r['rate']}% < min {r['min_rate']}%")
    if missing:
        failures.append("missing track(s): " + ", ".join(sorted(missing)))
    for failure in failures:
        print(f"[coverage-tracks] GATE FAIL: {failure}")
    if failures:
        return 1
    print("[coverage-tracks] gate ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

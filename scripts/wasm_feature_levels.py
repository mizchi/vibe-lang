#!/usr/bin/env python3
"""Classify WebAssembly proposals into vibe's two build levels using the
vendored WebAssembly/website support matrix (docs/wasm/feature-matrix.json,
refreshed by scripts/wasm_feature_matrix_fetch.sh -- the master data behind
https://webassembly.org/features/, not a scrape of that HTML page).

vibe draws a line between two levels (see docs/wasm/feature-levels.md):

  compiler-host   -- what runs the compiler itself (runtime/vibewt, a
                      wasmtime embedding). Experimental proposals + explicit
                      `-W ...=y` / Config flags are fine here; nothing here
                      is shipped to a vibe program's audience.
  codegen-<name>  -- what a *compiled vibe program* can rely on, keyed by a
                      named target engine set (see ENGINE_SETS below). No
                      flags: every engine in the set must support the
                      proposal unflagged, in a released (non-nightly) build.

A proposal is "level-safe" for an engine set iff every engine in that set
reports a plain supported status (boolean true or a version string) for it
-- null/false/["flag", ...] all disqualify it.

Usage:
  python3 scripts/wasm_feature_levels.py                 # human report
  python3 scripts/wasm_feature_levels.py --json           # machine report
  python3 scripts/wasm_feature_levels.py --check          # diff vs. the
                                                            # checked-in
                                                            # expected
                                                            # snapshot;
                                                            # nonzero exit
                                                            # on drift
  python3 scripts/wasm_feature_levels.py --update-expected  # write the
                                                              # snapshot
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MATRIX_PATH = os.path.join(ROOT, "docs", "wasm", "feature-matrix.json")
EXPECTED_PATH = os.path.join(ROOT, "docs", "wasm", "feature-levels.expected.json")

# Named codegen target engine sets. "v8" is the literal reading of "chrome,
# v8, deno, node" (Chrome/Node.js/Deno all embed V8, but ship it on
# different cadences, so listing them separately still catches lag).
# "web-baseline" additionally requires Firefox + Safari for engines that
# want portability beyond V8-family runtimes.
ENGINE_SETS = {
    "v8": ["Chrome", "Node.js", "Deno"],
    "web-baseline": ["Chrome", "Firefox", "Safari", "Node.js", "Deno"],
}

HOST_ENGINE = "Wasmtime"

# Proposals vibe's own codegen backends are currently known (via source
# grep, not binary inspection -- see docs/wasm/feature-levels.md) to emit.
# Keyed by feature-matrix.json key. This is intentionally a manually
# curated list, not derived from scanning emitted .wasm binaries; opcode-
# level verification is tracked as follow-up (see the doc).
USED_BY_CODEGEN = {
    "gc": "gc backend: struct.new/struct.get/struct.set (codegen/gc/backend_body.vibe)",
    "exceptionsFinal": "linear + gc backends: try_table/tag section, emitted only when a "
    "module uses effects/throw (codegen/wasi/linked_compile.vibe, codegen/gc/backend_expr.vibe)",
    "simd": "linear + gc backends: v128 opcodes behind specific builtins e.g. simd_skip_ws "
    "(codegen/wasm_emit/simd.vibe, codegen/expr/compile_call.vibe)",
}


def load_matrix():
    with open(MATRIX_PATH) as f:
        return json.load(f)


def engine_status(matrix, engine, feature_key):
    engine_entry = matrix["browsers"].get(engine)
    if engine_entry is None:
        return ("missing-engine", None)
    raw = engine_entry["features"].get(feature_key)
    if raw is None or raw is False:
        return ("unsupported", None)
    if raw is True:
        return ("supported", None)
    if isinstance(raw, str):
        return ("supported", raw)
    if isinstance(raw, list):
        status, note = raw[0], (raw[1] if len(raw) > 1 else None)
        if status == "flag":
            return ("flagged", note)
        return ("supported", status)
    return ("unknown", None)


def classify(matrix):
    features = matrix["features"]
    report = {"engineSets": {}, "host": {}}

    for level_name, engines in ENGINE_SETS.items():
        level = {}
        for key, meta in features.items():
            per_engine = {e: engine_status(matrix, e, key) for e in engines}
            safe = all(s[0] == "supported" for s in per_engine.values())
            level[key] = {
                "description": meta["description"],
                "phase": meta.get("phase"),
                "safe": safe,
                "engines": {e: {"status": s, "note": n} for e, (s, n) in per_engine.items()},
            }
        report["engineSets"][level_name] = level

    for key, meta in features.items():
        status, note = engine_status(matrix, HOST_ENGINE, key)
        report["host"][key] = {"description": meta["description"], "status": status, "note": note}

    report["usedByCodegen"] = {}
    for key, evidence in USED_BY_CODEGEN.items():
        entry = {"evidence": evidence, "engineSets": {}}
        for level_name in ENGINE_SETS:
            entry["engineSets"][level_name] = report["engineSets"][level_name].get(key, {}).get("safe")
        entry["hostStatus"] = report["host"].get(key, {}).get("status")
        report["usedByCodegen"][key] = entry

    return report


def print_human(report):
    print("== vibe wasm build levels (source: docs/wasm/feature-matrix.json) ==")
    print()
    print("-- proposals vibe codegen is known to emit --")
    for key, entry in sorted(report["usedByCodegen"].items()):
        levels = ", ".join(
            f"{name}={'OK' if safe else 'NOT SAFE'}" for name, safe in entry["engineSets"].items()
        )
        print(f"  {key}: host={entry['hostStatus']}  {levels}")
        print(f"    {entry['evidence']}")
    print()
    for level_name in ENGINE_SETS:
        level = report["engineSets"][level_name]
        unsafe = sorted(k for k, v in level.items() if not v["safe"])
        safe = sorted(k for k, v in level.items() if v["safe"])
        print(f"-- {level_name} ({', '.join(ENGINE_SETS[level_name])}) --")
        print(f"  safe ({len(safe)}): {', '.join(safe)}")
        print(f"  not safe ({len(unsafe)}): {', '.join(unsafe)}")
        print()


def main(argv):
    matrix = load_matrix()
    report = classify(matrix)

    if "--update-expected" in argv:
        with open(EXPECTED_PATH, "w") as f:
            json.dump(report, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"[wasm-feature-levels] wrote {EXPECTED_PATH}")
        return 0

    if "--check" in argv:
        if not os.path.exists(EXPECTED_PATH):
            print(f"FAIL: {EXPECTED_PATH} does not exist; run --update-expected", file=sys.stderr)
            return 1
        with open(EXPECTED_PATH) as f:
            expected = json.load(f)
        if json.dumps(report, sort_keys=True) != json.dumps(expected, sort_keys=True):
            print(
                "FAIL: classification drifted from docs/wasm/feature-levels.expected.json.\n"
                "Either the vendored matrix was refreshed and upstream engine support changed,\n"
                "or USED_BY_CODEGEN needs updating. Review the diff, update "
                "docs/wasm/feature-levels.md if the change is real, then re-run with "
                "--update-expected.",
                file=sys.stderr,
            )
            return 1
        print("[wasm-feature-levels] ok: matches docs/wasm/feature-levels.expected.json")
        return 0

    if "--json" in argv:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    print_human(report)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

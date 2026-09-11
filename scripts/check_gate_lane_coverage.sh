#!/usr/bin/env bash
# A caller that ENUMERATES compiler-gate lanes must name them all.
#
# scripts/compiler_gate.sh with no arguments runs every lane in GATE_LANES. A
# caller that passes lanes explicitly pins the set at the moment it was
# written, so adding a lane leaves that caller running the old set -- silently,
# because the caller still succeeds.
#
# That happened the day the `selftests` lane landed (#2650 review): the CI
# matrix selected it, `Taskfile.pkl`'s post-generation-gate still said
# `compiler_gate.sh early mid late`, and so the documented `pkf run full-gate`
# path stopped running the gate self-test ratchet entirely. Same shape as
# #2580, where three gates went dark and no gate noticed.
#
# `bootstrap` is the one exemption, and it is not a convention: the enumerating
# task runs AFTER the generation step that already ran that lane. Every other
# lane must appear.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="${VIBE_GATE_LANE_COVERAGE_ROOT:-$(dirname "$SCRIPT_DIR")}"
cd "$ROOT_DIR"

exec python3 - "$ROOT_DIR" <<'PYEOF'
import os, re, sys

root = sys.argv[1]
os.chdir(root)

EXEMPT = {"bootstrap"}          # already run by the generation step ahead of the caller

lib = "tests/gates/lib.sh"
try:
    with open(lib, encoding="utf-8") as fh:
        text = fh.read()
except OSError:
    print(f"[gate-lane-coverage] FAIL: cannot read {lib}", file=sys.stderr)
    sys.exit(1)

m = re.search(r'^GATE_LANES="([^"]*)"', text, re.M)
if not m:
    print(f"[gate-lane-coverage] FAIL: no GATE_LANES assignment in {lib} -- the scan "
          "has nothing to compare against, which is not the same as agreement",
          file=sys.stderr)
    sys.exit(1)
lanes = set(m.group(1).split())
if not lanes:
    print(f"[gate-lane-coverage] FAIL: GATE_LANES is empty in {lib}", file=sys.stderr)
    sys.exit(1)
required = lanes - EXEMPT

# The workflow is a caller too. Scanning only the Taskfile left the reverse of
# the defect this gate exists for: a workflow step edited to
# `compiler_gate.sh early mid late` drops the selftests lane from CI while both
# guards stay green (#2650 review).
CALLERS = ["Taskfile.pkl", ".github/workflows/ci.yml"]
# An invocation with trailing words that are lane names. `--list` and a bare
# call are not enumerations and are left alone.
CALL = re.compile(r'compiler_gate\.sh((?:[ \t]+[a-z][a-z0-9_-]*)+)')

rc = 0
seen_enumeration = False
for path in CALLERS:
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        print(f"[gate-lane-coverage] FAIL: cannot read {path} -- a caller that cannot "
              "be read is unchecked, not clean", file=sys.stderr)
        rc = 1
        continue
    for n, line in enumerate(lines, 1):
        # Prose mentions the script too ("// compiler_gate.sh runs it up front"),
        # and "runs it up front" is a run of lowercase words that the pattern
        # below would otherwise read as a lane list. A comment is not a caller.
        # `//` in pkl, `#` in YAML and in a shell `run:` block.
        if line.lstrip().startswith(("//", "#")):
            continue
        hit = CALL.search(line)
        if not hit:
            continue
        named = set(hit.group(1).split())
        if not named or not (named & lanes):
            continue          # trailing words that are not lanes at all
        seen_enumeration = True
        missing = sorted(required - named)
        unknown = sorted(named - lanes)
        if unknown:
            print(f"[gate-lane-coverage] {path}:{n} names lanes that do not exist: "
                  f"{', '.join(unknown)}", file=sys.stderr)
            rc = 1
        if missing:
            print(f"[gate-lane-coverage] {path}:{n} enumerates lanes and omits: "
                  f"{', '.join(missing)}", file=sys.stderr)
            print(f"    {line.strip()}", file=sys.stderr)
            print("  An enumeration pins the lane set at the moment it was written, so a "
                  "lane added later never runs here -- and this caller still passes.",
                  file=sys.stderr)
            print(f"  Add the lane, or drop the arguments so every lane in GATE_LANES runs.",
                  file=sys.stderr)
            rc = 1

if not seen_enumeration:
    # Silence here would mean "nothing enumerates lanes" and "the scan matched
    # nothing" equally well, and those are not the same answer.
    print("[gate-lane-coverage] FAIL: no lane enumeration found in "
          f"{', '.join(CALLERS)} -- the scan matched nothing, which is not a pass. "
          "If the enumerations were removed on purpose, remove this gate too.",
          file=sys.stderr)
    sys.exit(1)

if rc:
    sys.exit(1)
print(f"[gate-lane-coverage] ok ({len(required)} required lanes reach every enumeration)")
PYEOF

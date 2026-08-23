#!/usr/bin/env bash
# Adapter-selector precedence (#2239).
#
# cli_adapter.vibe dispatches on VIBE_* selectors in SOURCE ORDER, so a
# selector that leaks into the environment hijacks every verb whose own
# selector is evaluated later. That is not theoretical: measured on a real
# stage2, `VIBE_CHECK_ONLY=1 vibe fmt f.vibe` wrote `ok` OVER the source file,
# and `VIBE_FMT=1 vibe compile --wit f.vibe` wrote formatted vibe source as
# the .wit artifact -- both reporting success, because the output was
# non-empty.
#
# The launcher's defence is the `env -u` list on each arm. Keeping those lists
# right by hand does not work: #2239 shipped an arm whose list was copied from
# a neighbour and was missing six selectors, and the follow-up fixed one arm at
# a time and still missed three. So this check DERIVES the requirement from
# cli_adapter.vibe rather than restating it:
#
#   for every launcher `env` invocation that SETS selector S,
#   every selector cli_adapter evaluates BEFORE S must be cleared by that
#   invocation.
#
# Adding a selector to cli_adapter, or a verb to the launcher, cannot silently
# reopen the hole -- the requirement is recomputed from the source each run.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# The ratchet is GONE (#2243). It existed because 20 pre-existing arms carried
# the same exposure as the one #2239 introduced, and gating on them would have
# failed CI for unrelated reasons. All 20 now derive their clears from
# VIBE_SELECTOR_ORDER, so the full invariant is enforced by default and `--all`
# is just its explicit spelling. ENFORCED remains only as an escape hatch for
# bisecting a future regression down to one selector.
ENFORCED="${VIBE_SELECTOR_PRECEDENCE_ENFORCED:-}"
MODE="all"
if [ -n "$ENFORCED" ]; then MODE="enforced"; fi
if [ "${1:-}" = "--all" ]; then MODE="all"; shift; fi

ADAPTER="${1:-lib/@vibe/compiler/cli_adapter.vibe}"
LAUNCHER="${2:-runtime/vibe}"

python3 - "$ADAPTER" "$LAUNCHER" "$MODE" "$ENFORCED" <<'PY'
import re, sys

adapter, launcher, mode, enforced = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()

# Selector branch order, as cli_main evaluates it. VIBE_RC is a mode modifier
# read inside a branch, not a branch of its own.
order = []
for line in open(adapter, encoding="utf-8"):
    m = re.match(r'\s*(?:\} else )?if Env::get\("(VIBE_[A-Z_]+)"\) == "1" \{', line)
    if m and m.group(1) != "VIBE_RC" and m.group(1) not in order:
        order.append(m.group(1))

src = open(launcher, encoding="utf-8").read()

# The launcher embeds the adapter's selector order once (#2243) and derives each
# arm's clear list from it. That embedded order is the thing every arm now
# trusts, so verify it against the adapter before trusting it here.
m = re.search(r'VIBE_SELECTOR_ORDER="([^"]*)"', src)
if not m:
    print("[selector-precedence] FAIL: %s has no VIBE_SELECTOR_ORDER" % launcher, file=sys.stderr)
    sys.exit(1)
embedded = m.group(1).split()
if embedded != order:
    print("[selector-precedence] FAIL: VIBE_SELECTOR_ORDER is out of sync with %s" % adapter, file=sys.stderr)
    only_e = [x for x in embedded if x not in order]
    only_a = [x for x in order if x not in embedded]
    if only_e:
        print("  in the launcher but not the adapter: %s" % " ".join(only_e), file=sys.stderr)
    if only_a:
        print("  in the adapter but not the launcher: %s" % " ".join(only_a), file=sys.stderr)
    if not only_e and not only_a:
        print("  same names, different ORDER -- the clears would be computed against"
              " the wrong predecessor set", file=sys.stderr)
    sys.exit(1)

problems = []
for m in re.finditer(r'\benv\b((?:[^\n]*\\\n)*[^\n]*)', src):
    block = m.group(0)
    cleared = set(re.findall(r'-u (VIBE_[A-Z_]+)', block))
    # `env $(selector_clears_before T) ...` clears every predecessor of T.
    for t in re.findall(r'selector_clears_before (VIBE_[A-Z_]+)', block):
        if t in order:
            cleared.update(order[:order.index(t)])
    line_no = src[:m.start()].count("\n") + 1
    for i, sel in enumerate(order):
        if not re.search(r'(?<![-\w])' + sel + r'=1\b', block):
            continue
        preds = order[:i]
        if mode == "all":
            required = preds
        elif sel in enforced:
            # Rule 1 -- a block that SETS an enforced selector must clear every
            # predecessor. This is what protects `vibe fmt` itself, and it is
            # the rule the first version of this check silently omitted:
            # filtering the PREDECESSOR list by `enforced` left the fmt block
            # with nothing to require, because a selector cannot precede
            # itself. A new adapter selector added before VIBE_FMT would have
            # sailed through the gate built to catch exactly that.
            required = preds
        else:
            # Rule 2 -- every other block must clear an enforced selector that
            # precedes it. This is what stops VIBE_FMT hijacking other verbs.
            required = [e for e in preds if e in enforced]
        missing = [e for e in required if e not in cleared]
        if missing:
            problems.append((line_no, sel, missing))

if problems:
    print("[selector-precedence] FAIL: launcher arms that a leaked selector can hijack:", file=sys.stderr)
    for line_no, sel, missing in problems:
        print("  %s:%d sets %s but does not clear: %s"
              % (launcher, line_no, sel, " ".join(missing)), file=sys.stderr)
    print("  cli_adapter evaluates those BEFORE %s, so an inherited one wins and"
          % problems[0][1], file=sys.stderr)
    print("  its output is written as this verb's artifact.", file=sys.stderr)
    sys.exit(1)

if mode == "all":
    print("[selector-precedence] ok (audit: %d selectors, no arm can be hijacked)" % len(order))
else:
    print("[selector-precedence] ok (%d selectors; enforced: %s)" % (len(order), " ".join(enforced)))
PY

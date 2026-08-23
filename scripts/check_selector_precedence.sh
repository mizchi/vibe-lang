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
# Names that appear only in EXPRESSION position and do not pick a branch: they
# modify observation inside whichever branch was already selected, and a caller
# sets them deliberately (both are documented user-facing knobs). Clearing them
# would break that, so they are excluded BY NAME -- and the check below fails on
# any expression-position selector not accounted for here, so a new one cannot
# be silently dropped the way VIBE_COVERAGE was (#2246 review).
OBSERVATION_ONLY = {"VIBE_DIAGNOSTICS_ALL", "VIBE_PROFILE_MEMORY_MARKS"}

# The order is SOURCE ORDER, and a selector counts wherever it is tested --
# `let bytes = if Env::get("VIBE_COVERAGE") == "1" { .. } else if
# Env::get("VIBE_BACKEND") == "gc" { .. }` is a branch choice even though it is
# an expression. Matching only statement position missed VIBE_COVERAGE, so an
# inherited coverage flag silently produced a linear coverage build while the
# caller believed they had measured the gc lane.
order = []
expr_seen = []
for line in open(adapter, encoding="utf-8"):
    m = re.match(r'\s*(?:\} else )?if Env::get\("(VIBE_[A-Z_]+)"\) == "1" \{', line)
    if m:
        if m.group(1) != "VIBE_RC" and m.group(1) not in order:
            order.append(m.group(1))
        continue
    # VIBE_BACKEND is the one branch discriminator not compared against "1"
    # (`== "gc"`), and restricting the match to "1" silently dropped it -- so
    # `selector_clears_before VIBE_BACKEND` was clearing everything by accident
    # rather than by derivation. Every other non-"1" comparison in the adapter
    # (VIBE_RC, VIBE_TESTMETA_OUT, VIBE_CHECK_ERROR_ROW, VIBE_HOST_ACTION_OUT,
    # VIBE_ARTIFACT_INPUT_TRACE_NONCE) is a mode or a value, not a branch.
    for em in re.finditer(r'Env::get\("(VIBE_[A-Z_]+)"\) == "(?:1|gc)"', line):
        n = em.group(1)
        if n != "VIBE_RC" and n not in expr_seen:
            expr_seen.append(n)
        if n != "VIBE_RC" and n not in order and n not in OBSERVATION_ONLY:
            order.append(n)

# Fail closed on a selector this file has not classified. Every
# expression-position name must be either ordered above or named in
# OBSERVATION_ONLY with a reason; silence is what let VIBE_COVERAGE through.
unclassified = [n for n in expr_seen if n not in order and n not in OBSERVATION_ONLY]
if unclassified:
    print("[selector-precedence] FAIL: expression-position selectors with no"
          " classification: %s" % " ".join(unclassified), file=sys.stderr)
    print("  Add each to the order (it picks a branch or an artifact) or to"
          " OBSERVATION_ONLY with a reason.", file=sys.stderr)
    sys.exit(1)

src = open(launcher, encoding="utf-8").read()

# A clear target this derivation does not know is not a clear set -- it silently
# falls through selector_clears_before's loop and clears EVERYTHING, which looks
# like it works and is not derived from anything. Fail instead.
for t in sorted(set(re.findall(r'selector_clears_before (VIBE_[A-Z_]+)', src))):
    if t not in order:
        print("[selector-precedence] FAIL: selector_clears_before names %s, which is"
              " not a selector this derivation knows" % t, file=sys.stderr)
        print("  Its clear set would be 'everything', by accident rather than"
              " by derivation.", file=sys.stderr)
        sys.exit(1)

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
unverifiable = []
uninitialized = []
underived = []
for m in re.finditer(r'\benv\b((?:[^\n]*\\\n)*[^\n]*)', src):
    block = m.group(0)
    # FAIL CLOSED on what this scanner cannot read. An arm that selects its
    # adapter branch through a VARIABLE (`env $fs_env ...`) is invisible to the
    # literal `SELECTOR=1` match below -- and `vibe compile` was hijackable
    # that way while this check reported "no arm can be hijacked" (#2246
    # review). Silence about an unparsed arm is the same defect the check
    # exists to prevent, so an env block that runs the CLI through an
    # unresolved expansion must name a derived clear set explicitly.
    # Only blocks that run the runner ON THE CLI WASM select an adapter
    # branch. `env ... "$RUNNER" "$out"` executes the user's compiled program,
    # where no selector applies.
    runs_cli = '"$RUNNER"' in block and re.search(r'"?\$\{?cli\}?"?', block)

    # What this block actually CONSUMES, not what happens to sit near it.
    # Checking only for a nearby `selector_clears_before` credited proximity:
    # deleting `$sel_clears` from the invocation while leaving its computation
    # above left the check green (#2246 review). So: either the helper is
    # called inline in the block, or the block expands a variable this file
    # assigned from the helper.
    lookback = src[max(0, m.start() - 900):m.start()]
    inline = re.findall(r'\$\(selector_clears_before (VIBE_[A-Z_]+)\)', block)
    assigned = re.findall(r'(\w+)="?\$\(selector_clears_before (VIBE_[A-Z_]+)\)"?', lookback)
    consumed = [t for v, t in assigned if re.search(r'\$\{?' + v + r'\}?\b', block)]

    # "At least one derived assignment exists nearby" does not mean every path
    # takes one. With both assignments inside branches, deleting one leaves a
    # path where the variable is EMPTY and the block runs with NO clears -- the
    # gc lane did exactly that while this audit reported ok (#2248 review).
    #
    # Rather than approximate shell dataflow, require a shape whose coverage is
    # syntactic: the variable is DECLARED WITH a derived value (so every path
    # starts covered), and every later assignment to it is also derived (so no
    # path can narrow it to something underived). A bare `local VAR` leaves an
    # uncovered path and is rejected. This constrains how the launcher may be
    # written, which is the point -- it is checkable, and dataflow is not.
    for v, _t in assigned:
        if not re.search(r'\$\{?' + v + r'\}?\b', block):
            continue
        line_no = src[:m.start()].count("\n") + 1

        # EVERY assignment to the variable, wherever it hides. Anchoring on
        # line starts and `;`/`then`/`else`/`do` missed `&&` and `||`, so
        # `true && sel_clears=""` right before the invocation was ignored
        # (#2248 review). Rather than enumerate shell's separators -- the
        # enumeration is what keeps being incomplete -- match the assignment
        # ANYWHERE and let a false positive be the failure mode.
        found_decl = False
        for am in re.finditer(r'(?<![\w$])(local\s+)?' + v + r'=(?!=)([^\n]*)', lookback):
            if 'selector_clears_before' not in am.group(2):
                underived.append((line_no, v, am.group(2).strip()[:48] or "(empty)"))
            elif am.group(1):
                found_decl = True

        # A bare `local VAR` leaves an uncovered path...
        if re.search(r'\blocal\s+' + v + r'\s*$', lookback, re.M):
            uninitialized.append((line_no, v, "declared without a value"))
        # ...and so does no declaration at all. Only rejecting the BARE form
        # let the initialized `local VAR=...` line be deleted outright while
        # the conditional assignment remained, which either aborts under
        # `set -u` or -- worse -- takes an INHERITED value from the
        # environment straight into `env` (#2248 review).
        elif not found_decl:
            uninitialized.append((line_no, v, "never declared with a derived value"))

    covered = inline + consumed

    if runs_cli and re.search(r'\$\{?[a-z_]+\}?(?=\s)', block) and not covered:
        unverifiable.append(src[:m.start()].count("\n") + 1)
        continue
    cleared = set(re.findall(r'-u (VIBE_[A-Z_]+)', block))
    # Credit only what is guaranteed on EVERY path: when one variable is
    # assigned from the helper under several branches (compile_to picks
    # VIBE_BACKEND or VIBE_FS_COMPILE), the smallest predecessor set is the one
    # that always holds.
    if covered:
        weakest = min(order.index(t) for t in covered if t in order) \
            if any(t in order for t in covered) else None
        if weakest is not None:
            cleared.update(order[:weakest])
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

if uninitialized:
    print("[selector-precedence] FAIL: a derived clear variable is declared without a"
          " value, so some path reaches the runner with none:", file=sys.stderr)
    for line_no, v, why in uninitialized:
        print("  %s:%d -- %s: %s." % (launcher, line_no, v, why), file=sys.stderr)
        print("     Declare it WITH a selector_clears_before value and narrow after.",
              file=sys.stderr)
    sys.exit(1)

if underived:
    print("[selector-precedence] FAIL: a derived clear variable is also assigned"
          " something that is not derived:", file=sys.stderr)
    for line_no, v, rhs in underived:
        print("  %s:%d -- %s=%s" % (launcher, line_no, v, rhs), file=sys.stderr)
    sys.exit(1)

if unverifiable:
    print("[selector-precedence] FAIL: env blocks that run the CLI through an"
          " unresolved expansion:", file=sys.stderr)
    for line_no in unverifiable:
        print("  %s:%d -- this scanner cannot tell which adapter branch it selects,"
              % (launcher, line_no), file=sys.stderr)
        print("     so it must call selector_clears_before <SELECTOR> explicitly.",
              file=sys.stderr)
    sys.exit(1)

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

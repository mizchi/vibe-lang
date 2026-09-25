#!/usr/bin/env python3
"""Delta-debugging test-case reducer for fuzz findings (#765 task 2).

Given a failing seed (regenerated via tests/fuzz/gen_program.py) or a raw
.vibe file, and the finding class it produced (see tests/fuzz/run_fuzz.sh /
tests/fuzz/lib_oracle.sh for the exact vocabulary: MISMATCH, COMPILE_CRASH,
RUN_TRAP, COMPILE_HANG, RUN_HANG, COMPILE_DIAG), minimizes the program
while checking, after every candidate edit, that the SAME finding class
still reproduces -- via tests/fuzz/classify.sh, the same oracle
tests/fuzz/run_fuzz.sh uses per seed (both share tests/fuzz/lib_oracle.sh),
so "still reproduces" means exactly what run_fuzz.sh would have recorded.

Two reduction passes (CLIR paper's "diagnostic-driven hierarchical
test-case reduction" / semantic substitution, ported to vibe's line-
oriented generated source):

  1. Structural ddmin (statement/decl deletion): recursively splits the
     program into brace-depth-0 chunks -- first at the top level (whole
     struct/enum/fn/let declarations), then, for any chunk that opens a
     `{ ... }` body, recursively inside that body (so individual
     statements, and further-nested if/closure/while bodies, are
     candidates too) -- and ddmins each chunk list, keeping a removal iff
     the SAME class still reproduces.
  2. Expression-to-constant substitution: for single-line `let x = EXPR`
     / `x.field = EXPR` / `x = EXPR` statements, tries replacing the whole
     RHS with a small set of literal constants (0, 1, "", false, true);
     for bare integer literal tokens anywhere in the (already
     structurally-reduced) source, tries shrinking each toward 0. Both
     keep the substitution iff the class still reproduces.

Oracle classes (#2979: ORACLE_RENDER / ORACLE_THROW / ORACLE_CONT) carry
an expected.txt; the reducer keeps only the expectations whose println
survives in a candidate, requires the SAME failing id with the same per-lane
answer (3+-digit runs folded, since an address moves when an allocation is
deleted), and skips pass 2, which changes values by design. The expected
values were computed for the ORIGINAL program, so confirm the reduced
program's expected line still holds by reading it. Mutation-mode classes
(DIAG_NO_LOCATION / DIAG_INTERNAL_TOKEN) reduce a finding's mut.vibe with
classify.sh --mutate.

Caveat: classify.sh's class vocabulary is coarse (e.g. "COMPILE_DIAG"
covers ANY diagnostic on a well-typed generated program, not a specific
diagnostic message) -- for COMPILE_DIAG findings in particular, eyeball
the final diagnostic text to confirm the reduced program still exercises
the SAME diagnostic you started with, not a different, newly-introduced
one. For a MISMATCH/RUN_TRAP/RUN_HANG/COMPILE_CRASH/COMPILE_HANG finding
this ambiguity does not apply (there's exactly one behavior being
diffed/one way to crash/hang).

The FS-linked lane (defs.vibe + main.vibe) is intentionally NOT part of
what gets reduced: reduce.py minimizes single.vibe only, across the bump
(VIBE_RC=0) / RC (VIBE_RC=1) / wasm-gc (VIBE_BACKEND=gc) lanes. If a
finding is FS-lane-specific, reduce.py can still narrow it down (the
oracle will just never see the fs lane so such a finding would test as
"not reproduced" -- reduce by hand in that rarer case, e.g. by copying
the minimized single-file program's decls into defs.vibe/main.vibe).

Usage:
  python3 tests/fuzz/reduce.py <seed-or-path.vibe> --class CLASS [--cli PATH] [--out PATH] [--budget N] [--extended]

Examples:
  python3 tests/fuzz/reduce.py 217 --class MISMATCH
  python3 tests/fuzz/reduce.py _build/fuzz/findings/seed_217_MISMATCH/single.vibe \\
      --class MISMATCH --cli _build/selfhost/generations/init/stage2.wasm
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

FUZZ_DIR = Path(__file__).resolve().parent
ROOT_DIR = FUZZ_DIR.parent.parent
GEN_PROGRAM = FUZZ_DIR / "gen_program.py"
CLASSIFY_SH = FUZZ_DIR / "classify.sh"

FINDING_CLASSES = [
    "MISMATCH", "COMPILE_CRASH", "COMPILE_HANG",
    "RUN_TRAP", "RUN_HANG", "COMPILE_DIAG",
    # the lane-independent oracle (#2979, run_fuzz.sh --extended)
    "ORACLE_RENDER", "ORACLE_THROW", "ORACLE_CONT",
    # mutation mode's malformed diagnostics (#2979, run_fuzz.sh --mutate)
    "DIAG_NO_LOCATION", "DIAG_INTERNAL_TOKEN",
]
ORACLE_CLASSES = {"ORACLE_RENDER", "ORACLE_THROW", "ORACLE_CONT"}
DIAG_CLASSES = {"DIAG_NO_LOCATION", "DIAG_INTERNAL_TOKEN"}
DETAIL_RE = re.compile(r"(\w+)='([^']*)'")
ID_RE = re.compile(r"\bid=(\S+)")
LONG_DIGITS_RE = re.compile(r"\d{3,}")

CONST_CANDIDATES = ["0", "1", '""', "false", "true"]
ASSIGN_RE = re.compile(r'^(\s*)((?:let\s+(?:mut\s+)?[A-Za-z_]\w*|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*=\s*)(.*)$')
INT_RE = re.compile(r'(?<![\w.])\d+(?![\w.])')


# ---------- oracle plumbing ----------

class Oracle:
    """Wraps tests/fuzz/classify.sh: writes a candidate to workdir/single.vibe
    and reports whether it still reproduces the target finding class."""

    def __init__(self, workdir, target_cls, cli, budget, timeout=180,
                 expected=None):
        self.workdir = Path(workdir)
        self.target_cls = target_cls
        self.cli = cli
        self.budget = budget
        self.timeout = timeout
        self.calls = 0
        self.accepted = 0
        # ORACLE_* only: the full expected.txt lines, and the signature of
        # the original finding (failing id + what each lane printed there)
        # that a candidate must keep -- see oracle_signature.
        self.expected = expected or []
        self.signature = None

    def write_expected(self, text):
        """Keep only the expectations whose `println("<ID>|` survives in the
        candidate: a statement the reducer deleted no longer prints, and its
        absence is not a finding."""
        kept = [l for l in self.expected
                if f'"{l.split("|", 1)[0]}|' in text]
        (self.workdir / "expected.txt").write_text(
            "".join(l + "\n" for l in kept))

    @staticmethod
    def oracle_signature(detail):
        """(failing id, {lane: printed text}). A wrong answer that is an
        allocation ADDRESS moves whenever the reducer deletes an allocation,
        and must still count as the same finding, so runs of 3+ digits are
        folded to `#` -- but only when the expected text has no such run.
        When the right answer is itself a long number (a shift, a mask, a
        handler's sum), the lanes' digits are the finding and stay exact."""
        m = ID_RE.search(detail)
        pairs = DETAIL_RE.findall(detail)
        expected = "".join(v for k, v in pairs if k == "expected")
        fold = not LONG_DIGITS_RE.search(expected)
        lanes = {k: (LONG_DIGITS_RE.sub("#", v) if fold else v)
                 for k, v in pairs if k != "expected"}
        return (m.group(1) if m else None, lanes)

    def test(self, lines):
        if self.calls >= self.budget:
            return False
        self.calls += 1
        text = "\n".join(lines) + "\n"
        (self.workdir / "single.vibe").write_text(text)
        if self.target_cls in ORACLE_CLASSES:
            self.write_expected(text)
        cmd = ["bash", str(CLASSIFY_SH), str(self.workdir)]
        if self.target_cls in DIAG_CLASSES:
            cmd.append("--mutate")
        if self.cli:
            cmd += ["--cli", self.cli]
        try:
            proc = subprocess.run(
                cmd, cwd=str(ROOT_DIR), capture_output=True, text=True,
                timeout=self.timeout)
        except subprocess.TimeoutExpired:
            # classify.sh itself already applies COMPILE/RUN timeouts
            # internally; an external timeout here means something hung
            # even harder than expected. Treat as a hang classification.
            got = "RUN_HANG"
        else:
            out = proc.stdout.strip()
            got = out.split(" ", 1)[0] if out else "UNKNOWN"
        ok = got == self.target_cls
        if ok and self.target_cls in ORACLE_CLASSES:
            # The class alone is too coarse here: any deletion that changes
            # a printed value would "reproduce" it. Keep the original's
            # failing id and per-lane answer (see oracle_signature).
            sig = self.oracle_signature(out)
            if self.signature is None:
                self.signature = sig
            ok = sig == self.signature
        if ok:
            self.accepted += 1
        return ok


# ---------- structural (statement/decl) ddmin ----------

def flatten(chunks):
    out = []
    for c in chunks:
        out.extend(c)
    return out


def split_depth0_chunks(lines):
    """Group `lines` into maximal runs that start and end at brace-depth 0
    (relative to the start of this list). Each top-level decl (struct/
    enum/let/fn) -- or, one level down, each statement/nested block --
    becomes one chunk. Assumes no unbalanced `{`/`}` hides inside string
    literals or comments, true of tests/fuzz/gen_program.py's own output and of
    ordinary vibe source without brace characters embedded in string
    bodies (string interpolation's `\\{expr}` is itself a balanced brace
    pair, so it doesn't violate this)."""
    chunks = []
    cur = []
    depth = 0
    for line in lines:
        cur.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            chunks.append(cur)
            cur = []
            depth = 0
    if cur:
        chunks.append(cur)
    return chunks


def split_body(chunk_lines):
    """If `chunk_lines` opens a `{ ... }` body (a struct/enum/fn/let decl,
    or a nested if/closure/while block), return (header, inner, footer)
    where header/footer are line lists and inner is the body's lines with
    the SAME depth-0-chunking property reduce_program relies on. Returns
    (None, None, None) if there's no reducible inner body."""
    first_open = None
    for i, l in enumerate(chunk_lines):
        if "{" in l:
            first_open = i
            break
    if first_open is None:
        return None, None, None
    depth = 0
    last_close = None
    for i in range(first_open, len(chunk_lines)):
        depth += chunk_lines[i].count("{") - chunk_lines[i].count("}")
        if depth == 0:
            last_close = i
            break
    if last_close is None or last_close <= first_open:
        return None, None, None
    header = chunk_lines[:first_open + 1]
    inner = chunk_lines[first_open + 1:last_close]
    footer = chunk_lines[last_close:]
    if not inner:
        return None, None, None
    return header, inner, footer


def ddmin(elems, test):
    """Zeller-style delta-debugging: shrink `elems` to a sublist where
    test(sublist) still holds, assuming test(elems) already holds. Chunk-
    removal variant (increasing granularity n=2,4,8,...) -- simple and
    effective for this use case."""
    if not elems:
        return elems
    n = 2
    while len(elems) >= 1:
        chunk_size = max(1, (len(elems) + n - 1) // n)
        chunks = [elems[i:i + chunk_size] for i in range(0, len(elems), chunk_size)]
        if len(chunks) < 2:
            break
        reduced = False
        for i in range(len(chunks)):
            candidate = [e for j, c in enumerate(chunks) if j != i for e in c]
            if candidate and test(candidate):
                elems = candidate
                n = max(n - 1, 2)
                reduced = True
                break
        if reduced:
            continue
        if n >= len(elems):
            break
        n = min(n * 2, len(elems))
    return elems


def reduce_program(lines, test, max_depth=16):
    """Recursively ddmin `lines` at successive brace-depth granularities:
    whole top-level decls first, then per-statement inside each remaining
    decl body, recursing into nested bodies (if/else, closures, while)
    too. `test(full_candidate_lines) -> bool` always re-verifies the
    WHOLE program (other parts held fixed), never just the local slice."""
    if max_depth <= 0:
        return lines
    chunks = split_depth0_chunks(lines)

    def test_chunks(selected):
        return test(flatten(selected))

    chunks = ddmin(chunks, test_chunks)

    for idx in range(len(chunks)):
        header, inner, footer = split_body(chunks[idx])
        if inner is None:
            continue

        def test_inner(candidate_inner, idx=idx, header=header, footer=footer):
            trial = list(chunks)
            trial[idx] = header + candidate_inner + footer
            return test(flatten(trial))

        reduced_inner = reduce_program(inner, test_inner, max_depth - 1)
        chunks[idx] = header + reduced_inner + footer
    return flatten(chunks)


# ---------- expression-to-constant substitution ----------

def substitute_constants(lines, test):
    lines = list(lines)
    for i, line in enumerate(lines):
        if "{" in line or "}" in line:
            continue  # multi-line/block-shaped statement, skip here
        m = ASSIGN_RE.match(line)
        if not m:
            continue
        indent, prefix, rhs = m.groups()
        rhs = rhs.strip()
        if not rhs or rhs in CONST_CANDIDATES:
            continue
        for cand in CONST_CANDIDATES:
            trial = list(lines)
            trial[i] = f"{indent}{prefix}{cand}"
            if test(trial):
                lines = trial
                break
    return lines


def shrink_int_literals(lines, test):
    lines = list(lines)
    changed = True
    while changed:
        changed = False
        for i in range(len(lines)):
            line = lines[i]
            for m in list(INT_RE.finditer(line))[::-1]:
                val = int(m.group(0))
                if val == 0:
                    continue
                for cand in sorted({0, 1, val // 2}, reverse=True):
                    if cand == val:
                        continue
                    trial_line = line[:m.start()] + str(cand) + line[m.end():]
                    trial = list(lines)
                    trial[i] = trial_line
                    if test(trial):
                        lines[i] = trial_line
                        line = trial_line
                        changed = True
                        break
    return lines


# ---------- CLI ----------

def load_target(target, workdir, gen_args):
    """Returns (source lines, expected.txt lines) for `target` (a seed
    number or a path to a .vibe file), writing the source (and nothing else
    -- no main.vibe/defs.vibe, so classify.sh sticks to the single-file
    lanes) into workdir/single.vibe. The oracle's expected.txt and the
    lane skips (skip_lanes) come along: from the generator for a seed, from
    beside the file for a path (run_fuzz.sh copies both into a finding)."""
    expected = []
    if target.isdigit():
        gen_dir = Path(tempfile.mkdtemp(prefix="vibe-reduce-gen-"))
        subprocess.run(
            [sys.executable, str(GEN_PROGRAM), target, str(gen_dir)] + gen_args,
            check=True)
        src_dir = gen_dir
        text = (gen_dir / "single.vibe").read_text()
    else:
        gen_dir = None
        src_dir = Path(target).resolve().parent
        text = Path(target).read_text()
    if (src_dir / "expected.txt").exists():
        expected = (src_dir / "expected.txt").read_text().splitlines()
    if (src_dir / "skip_lanes").exists():
        shutil.copy(src_dir / "skip_lanes", workdir / "skip_lanes")
    if gen_dir is not None:
        shutil.rmtree(gen_dir, ignore_errors=True)
    (workdir / "single.vibe").write_text(text)
    return text.splitlines(), expected


def main():
    ap = argparse.ArgumentParser(
        description="Delta-debugging reducer for fuzz findings (#765).")
    ap.add_argument("target", help="seed (integer) or path to a .vibe file")
    ap.add_argument("--class", dest="cls", required=True,
                     choices=FINDING_CLASSES,
                     help="finding class the program must keep reproducing")
    ap.add_argument("--cli", default=None,
                     help="stage2.wasm CLI (default: latest generation, "
                          "same lookup as run_fuzz.sh)")
    ap.add_argument("--out", default=None,
                     help="where to write the reduced .vibe (default: "
                          "_build/fuzz/reduced/<name>.vibe)")
    ap.add_argument("--budget", type=int, default=4000,
                     help="max oracle invocations (compile+run cycles)")
    ap.add_argument("--extended", action="store_true",
                     help="regenerate a SEED target with gen_program.py "
                          "--extended (the #2979 productions and oracle)")
    ap.add_argument("--classic", action="store_true",
                     help="regenerate a SEED target with --classic")
    args = ap.parse_args()
    if args.cls in DIAG_CLASSES and args.target.isdigit():
        ap.error(f"{args.cls} is a mutation-mode class: pass the finding's "
                 "mut.vibe, not a seed")
    gen_args = (["--extended"] if args.extended else []) + (
        ["--classic"] if args.classic else [])

    workdir = Path(tempfile.mkdtemp(prefix="vibe-reduce-"))
    lines, expected = load_target(args.target, workdir, gen_args)
    if args.cls in ORACLE_CLASSES and not expected:
        ap.error(f"{args.cls} needs the program's expected.txt (a seed with "
                 "--extended, or a finding directory's single.vibe)")
    oracle = Oracle(workdir, args.cls, args.cli, args.budget,
                    expected=expected)

    print(f"[reduce] target={args.target} class={args.cls} "
          f"lines={len(lines)} budget={args.budget}")
    print("[reduce] verifying the original reproduces the target class...")
    if not oracle.test(lines):
        print(f"[reduce] ERROR: original does not reproduce {args.cls}; "
              f"nothing to reduce (check --class / --cli)", file=sys.stderr)
        shutil.rmtree(workdir, ignore_errors=True)
        sys.exit(1)

    reduced = reduce_program(lines, oracle.test)
    if args.cls not in ORACLE_CLASSES:
        # Both passes CHANGE VALUES by design, and an oracle finding is a
        # value compared against one computed for the original program:
        # substituting a constant would make it mismatch for a new reason.
        reduced = substitute_constants(reduced, oracle.test)
        reduced = shrink_int_literals(reduced, oracle.test)
    # constant substitution can expose newly-dead statements (e.g. a
    # struct literal is now only ever used as a constant), so run one more
    # structural pass to mop those up.
    reduced = reduce_program(reduced, oracle.test)

    out_path = Path(args.out) if args.out else (
        ROOT_DIR / "_build/fuzz/reduced" /
        f"{Path(args.target).stem if not args.target.isdigit() else 'seed_' + args.target}_{args.cls}.vibe")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_text = "\n".join(reduced) + "\n"
    out_path.write_text(out_text)

    print(f"[reduce] {len(lines)} -> {len(reduced)} lines "
          f"({oracle.calls} oracle calls, {oracle.accepted} accepted)")
    print(f"[reduce] wrote {out_path}")
    if args.cls in ORACLE_CLASSES:
        exp_path = out_path.with_suffix(".expected.txt")
        oracle.write_expected(out_text)
        exp_path.write_text((workdir / "expected.txt").read_text())
        print(f"[reduce] wrote {exp_path}")
    print("---")
    print(out_text)
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()

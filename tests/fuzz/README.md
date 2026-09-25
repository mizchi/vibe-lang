# fuzz — selfhost compiler differential fuzzing

Source lives at `tests/fuzz/`; generated work and findings stay in `_build/fuzz/`.

A generative fuzzing harness that hunts compiler bugs: miscompiles, crashes,
hangs, divergence between backends and lanes, wrong answers that every lane
shares, and malformed diagnostics. It was confirmed to catch #722-class bugs
(first-match struct field resolution that ignored the type) automatically: 2 of
8 seeds reported MISMATCH against the compiler from before the fix.

## Usage

```bash
# Generative differential mode (default): seeds A..B, liveness-aware bias on
bash tests/fuzz/run_fuzz.sh --seeds 1..300

# The #2979 productions and the lane-independent oracle (see below)
bash tests/fuzz/run_fuzz.sh --extended --seeds 1..300

# Classic generation only (liveness-aware bias off, the pre-#765 behavior)
bash tests/fuzz/run_fuzz.sh --classic --seeds 1..300

# Force the liveness-aware bias (0.0..1.0, for testing; not with --classic)
bash tests/fuzz/run_fuzz.sh --liveness-bias 0.85 --seeds 1..300

# Parser robustness (byte mutation): a compiler trap or hang, or a malformed
# diagnostic, is a finding
bash tests/fuzz/run_fuzz.sh --mutate --seeds 1..300

# Name the compiler (default: HEAD's own generation, refused if there is none)
bash tests/fuzz/run_fuzz.sh --seeds 1..50 --cli _build/selfhost/generations/<gen>/stage2.wasm
```

Findings are saved under `_build/fuzz/findings/seed_<seed>_<class>/` (inputs,
logs, each lane's stdout, `note.txt`, and for `--extended` the program's
`expected.txt` and `skip_lanes`), and listed in `_build/fuzz/failing_seeds.txt`.
Generation is seed-deterministic, so `python3 tests/fuzz/gen_program.py <seed>
<dir> [--extended]` regenerates a program (`--classic` turns the bias off,
`--liveness-bias=X` sets it).

`tests/fuzz/reduce.py` minimizes a finding automatically (below).

## What is compared (the oracles)

Each seed's program is compiled and run four ways, and the results must agree:

| lane | compile | run |
| ---- | ------- | --- |
| bump | `VIBE_RC=0` | node host runner |
| RC   | `VIBE_RC=1` (production default) | node host runner |
| gc   | `VIBE_BACKEND=gc` | `wasmtime -W gc=y,function-references=y,exceptions=y` |
| FS-linked | the split program (defs.vibe + main.vibe) with `VIBE_FS_COMPILE=1` | node host runner |

Generated programs are well-typed, so a diagnostic is a finding (COMPILE_DIAG).
So are a compiler or runtime trap (COMPILE_CRASH / RUN_TRAP), a timeout
(COMPILE_HANG / RUN_HANG) and a disagreement between lanes (MISMATCH).

### The lane-independent oracle (`--extended`, #2979)

A differential oracle cannot see a wrong answer that every lane shares, and the
2026-09 audit's P0s were all of that shape. With `--extended`, each production
whose value is known at generation time prints one line `<ID>|<text>`, and the
generator writes the text it must be into `expected.txt`. Every lane's stdout
is checked against it, by ID. The ID's first letter names the oracle and the
finding class:

| ID | class | what is known at generation time |
| -- | ----- | -------------------------------- |
| `R<n>` | ORACLE_RENDER | a value built from literals (`Some(Some(1))`, `[None, Some(0)]`), an annotated `Int::parse("42")`, a builtin call inside `"\{..}"`, a labeled-argument call, an unbounded or trait-bounded generic call, a shift count outside 0..62 |
| `T<n>` | ORACLE_THROW | `throw(K(..))` under `handle .. with Exception[K]::Throw(e) => <render e>`, and nested handles discharging a mixed row |
| `C<n>` | ORACLE_CONT | a handler arm's answer: resuming (`resume(v)`, with a `let mut` counter updated in a Unit arm) or LEAVING (`return v`, `throw(..)`), which per ADR-0114 ends the enclosing function or handle |

The expected text comes from a small Python model of exactly these shapes
(masked integer arithmetic, the renderer's container spelling, the handler
semantics) — not from a second evaluator for the language. The generated
`main` stays a plain differential program; only these productions carry an
oracle line. A verdict names the first failing ID and, in `failing=`, every
failing ID, so one bug that fires in most programs does not hide the others.

### Diagnostic quality (`--mutate`, #2979)

A mutated program is expected to be rejected, but not by any diagnostic at all:

- `DIAG_NO_LOCATION`: the diagnostic carries no `line N:M`.
- `DIAG_INTERNAL_TOKEN`: it reports an unexpected separator (`;` `,` `:` or a
  bracket) that the source does not contain, i.e. a token the compiler
  synthesized rather than one it read.

A compiler trap or hang is still `MUT_COMPILE_CRASH` / `MUT_COMPILE_HANG`.
`bash tests/fuzz/classify.sh DIR --mutate` gives the same verdict for one input.

`tests/fuzz/classify_test.sh` (`pkf run check-fuzz-classify`) proves both
checks and the oracle can fail. It runs the real classify.sh against a stubbed
compiler and stubbed runtimes, so the diagnostics and outputs under test are
fixed, and it pairs each red case with a mutant of lib_oracle.sh that has the
check removed.

## Generator design (tests/fuzz/gen_program.py)

- **Trap-free by construction**: all arithmetic is masked with `& 1048575`
  (small, non-negative), a divisor is `1 + (e & 15)`, a shift count is `& 15`,
  an array index is a masked non-negative value `% len`, and loops have literal
  bounds. Every runtime trap is therefore a compiler bug.
- **Known bug classes generated on purpose, often**: struct families with
  same-named fields at different slots (#722), struct literals in a different
  order from the declaration, stores to `mut` fields, `Option[Struct]` returned
  across a function boundary and then read, closures with a mutable capture,
  for-in comprehensions (#538), exhaustive enum matches, string interpolation,
  tuple projection, guarded div/mod.
- **Liveness-aware bias (#765, on by default)**: ported from the CLIR paper's
  (arXiv 2606.26977) liveness-driven generation. `Gen.liveness_bias` is drawn
  per seed from `0.12..0.55` (`--classic` sets 0, `--liveness-bias=X` sets it),
  and with that probability each `gen_stmts` statement is replaced by one of
  the shapes below. It is a bypass in front of the existing menu, not a
  replacement, so no existing coverage is lost:
  - `gen_def_use_chain`: a value (a struct or an Int) made early is threaded
    through 3–6 intermediate lets or helper calls and consumed only at a sink
    at the end. Stresses dup/drop accounting over long live ranges.
  - `gen_alias_stmts`: `let b = a`, then both `a` and `b` are used. Stresses
    the RC dup on alias creation.
  - `gen_conditional_move`: only one branch of an `if` consumes (moves) the
    value through a helper call; the other never touches it. Stresses the drop
    on the untouched branch and later uses after the `if`.
  - `gen_cross_scope_capture`: a closure defined inside an `if` branch captures
    an outer `let` (a struct) or a `mut`, and is called after the `if`.
    Stresses capture-time dup accounting.
  - **Tail-resume approximation** (a light version of #737, no handler needed):
    `carry_walkN(n: Int, carried: Sx) -> Int` recurses without touching
    `carried` and consumes it only at the base case. The depth is always a
    literal (5..15) at the call site, never a generated value, so it cannot
    hang.
- **Extended productions (#2979, `--extended`)**: `ExtGen` adds, from its own
  random stream (so a seed's base program is the same either way):
  - user effects (`effect` with an `Int -> Int` and an `Int -> Unit`
    operation), helpers that `perform` them, and handles whose arms resume,
    `return`, or `throw`; arms are written in declaration order (#3058);
  - exception kinds (`derive(Show)` enums and `suberror`), throwing helpers
    with `Exception[K]` rows, and helpers whose row mixes a user effect and a
    kind, spelled with `+` or through an `effectset`;
  - nested containers `Option[Option[T]]`, `Array[Option[T]]`,
    `Option[Array[T]]` and deeper, annotated, or bare when the literal
    describes itself; matches on `Option[Option[Int]]` and on `Array::get`;
  - builtin calls (`String::length` / `concat` / `substring` / `contains` /
    `starts_with` / `ends_with`, `Array::length`) directly inside `"\{..}"`;
  - labeled arguments passed out of order into a non-commutative body, an
    unbounded generic at two instantiations, a trait with impls for `Int` and
    a struct called through `[T: Tr]` bounds (qualified and UFCS);
  - shift counts outside 0..62.

  Every generated function carries an effect ROW, and `_start` discharges each
  row with nested handles (user effects inside, the exception outside), so the
  entry needs only `Stdout`. Every effect and throwing helper is called at least
  once.

### Known lane gaps (`skip_lanes`)

Some constructs do not compile on one lane today. Rather than drop them, the
generator writes the lanes a program cannot use to `skip_lanes`; classify.sh
does not compile those lanes and reports them as `skipped` in every verdict.

| construct | lanes skipped | why (measured 2026-09-24) |
| --------- | ------------- | ------------------------- |
| trait impls / bounded generics | bump, rc | the flat single-source linear lane answers ``no impl `Tr` for `Self` `` (and a `__dict_` reserved-prefix error) for a program the gc and FS lanes accept |
| `suberror` kinds | fs | `export suberror K(..)` is not exported: `imported name 'K' is not exported` |

Two more gaps are avoided rather than skipped, because they would reject every
program: the gc lane refuses a program with an UNCALLED function that performs
a user effect (`GC codegen: unsupported perform`), so every helper is called;
and interpolating an unannotated `Option` result (`"\{Int::parse("42")}"`) is
refused on the linear lanes (#2987), so `Int::parse` is bound with an
annotation first.

## Automatic test-case reducer (tests/fuzz/reduce.py, #765)

A delta-debugging tool that minimizes a finding while the SAME finding class
still reproduces (a port of the CLIR paper's diagnostic-driven hierarchical
test-case reduction and semantic substitution).

```bash
# from a seed: regenerate the failing program and minimize it
python3 tests/fuzz/reduce.py 217 --class MISMATCH
python3 tests/fuzz/reduce.py 12 --class ORACLE_CONT --extended

# from a finding's files (expected.txt / skip_lanes beside it are picked up)
python3 tests/fuzz/reduce.py _build/fuzz/findings/seed_217_MISMATCH/single.vibe \
  --class MISMATCH --cli _build/selfhost/generations/<gen>/stage2.wasm
python3 tests/fuzz/reduce.py _build/fuzz/findings/seed_9_DIAG_NO_LOCATION/mut.vibe \
  --class DIAG_NO_LOCATION
```

- The oracle is `tests/fuzz/classify.sh`, which shares the compile, run and
  finding-class logic with `run_fuzz.sh` through `tests/fuzz/lib_oracle.sh`.
  Classes: `MISMATCH` / `COMPILE_CRASH` / `COMPILE_HANG` / `RUN_TRAP` /
  `RUN_HANG` / `COMPILE_DIAG` / `ORACLE_RENDER` / `ORACLE_THROW` /
  `ORACLE_CONT` / `DIAG_NO_LOCATION` / `DIAG_INTERNAL_TOKEN`.
- Two passes: (1) brace-depth recursive ddmin (top-level declarations, then
  statements, then nested if/closure/while bodies); (2) expression-to-constant
  substitution (`let x = EXPR` → `0`/`1`/`""`/`false`/`true`) and integer
  shrinking. Each edit is kept only if the class still reproduces.
- ORACLE classes: the reducer keeps only the expectations whose `println`
  survives, requires the SAME failing ID with the same per-lane answer (runs of
  three or more digits folded, because an address moves when an allocation is
  deleted), and skips pass (2), which changes values by design. The expected
  values were computed for the original program, so read the reduced program's
  expected line and confirm it still holds. `<out>.expected.txt` is written
  beside the result.
- The FS-linked lane (defs.vibe + main.vibe) is not reduced: only single.vibe is,
  on the bump/RC/gc lanes. Move the reduced declarations into
  defs.vibe/main.vibe by hand for an FS-only finding.
- `COMPILE_DIAG` is a coarse class ("a diagnostic appeared"), so check that the
  reduced program's diagnostic is the same problem as the original's.
- Output goes to `_build/fuzz/reduced/<name>_<class>.vibe` (override with
  `--out`). `--budget` caps the oracle calls (default 4000; each is about three
  compiles and three runs).

## Campaign reference numbers

Record these as the baseline for later campaigns, with the compiler named.

**2026-07-07, HEAD of that day** (before #2979): about 1900 differential seeds
with liveness-aware generation (default, `--liveness-bias 0.85` and `0.95`
mixed, seeds 1..1300), plus 50 `--classic` and 200 `--mutate` seeds: 0
findings, consistent with #725/#737/#745 being fixed.

**2026-09-24, stage2 of main at f5fa92eb9** (this change, `--jobs 4`):

| mode | seeds | findings | by class |
| ---- | ----- | -------- | -------- |
| default (liveness) | 1..40 | see below | |
| `--extended` | 1..60 | see below | |
| `--mutate` | 1..200 | see below | |

The `--extended` findings are real compiler bugs, not generator noise; each was
reproduced by a minimal hand-written program:

1. **`return` in a handler arm resumes when the `perform` is in a callee**
   (ORACLE_CONT, every lane). `handle { ask(3) + 1 } with { Cfg::Get(x) =>
   return x + 40 }`, where `ask` performs `Cfg::Get`, continues the body as if
   the arm had resumed with `x + 40` (the function answers 1440, not 43). With
   the `perform` written directly in the handle body it answers 43.
2. **A kinded exception payload interpolated directly renders an address**
   (ORACLE_THROW, every lane). `Exception[K]::Throw(e) => "caught \{e}"` with
   `K` `derive(Show)` prints `caught 233`; `let k: K = e` first, or `match e`,
   prints `caught KA(5)`.
3. **An unannotated literal loses its element type when rendered**
   (ORACLE_RENDER, every lane): `let a = Some(Some(false))` renders
   `Some(Some(0))`, `[Some(true)]` renders `[Some(1)]`, and `[Some([1]), None]`
   renders `[Some(<address>), None]`. The annotated bindings render correctly.
4. **`String::substring` does not clamp on the gc lane** (ORACLE_RENDER, gc
   only): `substring("beta", 0, 5)` is `beta]`, `substring("beta", -1, 1)` reads
   the byte before the string, and an end before the start prints an address
   instead of `""`. The linear lanes clamp as the cheatsheet says.

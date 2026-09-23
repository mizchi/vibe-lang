# Borrowing and vectorization for vibe: a designed-in subset

Proposal, 2026-09-23. Not an ADR. It draws on the notes in this directory
([bend.md](bend.md), [mojo.md](mojo.md), [vx.md](vx.md),
[moonbit-veri.md](moonbit-veri.md)). It asks one question: **if vibe designs
these in now, can it meet the constraints by restricting them to specific
patterns, rather than by adopting a full borrow checker or a general
auto-vectorizer?**

Short answer: yes, for both, and the two subsets meet at one rule — **a
mutable buffer argument does not alias any other argument**. That rule is what
a verifier needs (veri's blit split), what an in-place vector kernel needs,
and what Perceus needs to drop its run-time uniqueness test.

Proposed syntax below is illustrative (` ```vibe skip `) and not decided.

## 0. Constraints this has to satisfy

From the design policy in `AGENTS.md`, in its own priority order:

1. **Never silently wrong.** A vectorized kernel must give the same answer as
   the scalar loop, bit for bit, traps included. A borrow annotation that the
   checker does not read is not allowed (Bend's `!`).
2. **Honest representation, close to wasm.** A value is a tagged i64. *A vector
   never becomes a vibe value* ([simd-api-design.md](../../internal/design/simd-api-design.md)):
   that invariant stays. The target has 128-bit `v128` and nothing wider;
   relaxed SIMD is nondeterministic by specification.
3. **Diagnostics lead with the edit**, and the CLI answers the question
   ("was this vectorized, and if not, why?") line by line.

And from the other languages:

- global affinity costs too much expressiveness (Bend's five walls);
- lifetimes in the surface are avoidable for the common case (Mojo);
- scope-depth lifetime approximations are unsound (Vx);
- a proof that is not connected to the implementation certifies the model
  (Bend's Lean file); verification of mutating code needs alias freedom and a
  pre-state (veri).

## 1. What vibe already has

This proposal is mostly about **surfacing and checking what the compiler
already infers**, which is why it is cheaper than it sounds.

| existing piece | where | what it gives |
|---|---|---|
| per-parameter borrow mask, whole-program fixpoint | `compute_borrow_param_user_fns` in `codegen/common_analysis/common_analysis.vibe` | which parameters are never consumed |
| `borrow_ret`, `view_ret`, `scalar_ret` sets | `runtime/rc_query.vibe` (`vibe rc-classify`) | which results alias a parameter |
| consume counting | `md_consume_count` in `common_analysis.vibe` | the usage map Bend uses, already computed |
| guarded constructor reuse | ADR-0092, [perceus-reuse.md](../../internal/design/perceus-reuse.md) | in-place reuse behind a run-time `rc == 1` test |
| region tokens and escape errors | ADR-0090, `checker/checker.vibe` | return / outer-binding / container-write / capture escape checks |
| `Send` as a compiler-judged marker | `checker/checker_trait.vibe` | a structural "shareable" classifier, like Bend's `Data` |
| checked annotation with interprocedural summaries | `#zero_alloc` (ADR-0091) | the shape a `#vectorize` check should copy |
| `where { requires, ensures }` | ADR-0064 | the contract surface, runtime traps today |
| Lean models with executable oracles diffed against the selfhost | `formal/check-oracle.sh` | the way to keep a model tied to the implementation |
| v128 emitters and inline wasm | `codegen/wasm_emit/simd.vibe`, ADR-0072 | byte-oriented SIMD only; no i32x4 / f64x2 arithmetic emitters yet |

What is missing: none of the ownership facts is **declarable**, so they cannot
cross a package contract (`index.vpkg`) or be relied on by a verifier; the
uniqueness behind reuse is only ever checked at run time; and there is no packed
numeric buffer for a vector loop to run over (§3.3 of
[simd-data-structures.md](../../internal/design/simd-data-structures.md)).

## Part A — borrow modes as a checked contract

### A1. Scope: second-class, parameters only

Take Mojo's conventions, not Rust's references. A mode is attached to a
**parameter**, never to a type, so a borrowed thing can never be stored,
returned or captured. With that one restriction there are no lifetime
variables to infer, compare or print — the Vx trap does not arise, because no
lifetime comparison is made at all.

```vibe skip
// proposed
fn total(borrow xs: Array[Int]) -> Int { ... }          // never consumed, never escapes
fn fill(mut dst: Array[Int], borrow src: Array[Int]) -> Unit { ... }  // dst written, disjoint from src
fn finish(consume b: ArrayBuilder[Int]) -> Array[Int] { ... }         // ownership passes in
```

| mode | callee may | caller gets | checked by |
|---|---|---|---|
| *(none)* | anything (today's semantics) | inferred ABI, as now | nothing new |
| `borrow` | read; pass to another `borrow` position | no transfer dup, no drop | consume count = 0 and no escape |
| `mut` | write through it | the argument does not alias any other argument | exclusivity (A3) |
| `consume` | keep, return, store, reuse in place | the binding is dead after the call | usage map at the call site (A4) |

Unannotated code does not change. A mode is an opt-in promise that the checker
verifies and that the ABI can then rely on across a package boundary.

### A2. `borrow` is a region the length of the call

A `borrow` parameter is exactly a region token whose extent is the call. The
escape checks vibe already runs for `region r { }` and `TaskGroup::run` —
return, outer binding, container write, closure capture — are the escape
checks a borrow needs. Reusing them avoids a second escape analysis, and it
closes one of the documented holes on the way: a `borrow` is a parameter, not
a generalized `let`, so the "leak through a generalized local" gap does not
apply to it.

Checking a declared `borrow` against the inferred mask is the first slice, and
it changes no code generation: it only turns an inference into a contract. The
contract is the payoff. The borrow fixpoint is whole-program today, and
module-granular incremental checking (#1379) cannot keep a whole-program
fixpoint; a mode written in `index.vpkg` can be.

### A3. `mut`: exclusivity, restricted to shallow buffers

Mojo's rule is "a `mut` argument cannot alias any other argument". vibe cannot
check it the way Mojo does, because in vibe `let b = a` on an `Array` shares the
heap object (Mojo copies). A purely syntactic check is therefore unsound, and
tracking aliases in general is a whole borrow checker.

The subset that makes it tractable:

- **`mut` is allowed only on shallow buffer types**: `Array[S]` with a scalar
  `S`, `Bytes`, `FixedArray[S]`, `MutBytes[r]`, and the packed columns of Part B.
  A shallow buffer can only alias another value by *being the same object*,
  never by containing it.
- **Static where decidable:** two arguments that are the same place, or where
  one place is a prefix of the other (`s` and `s.buf`), are a compile error.
- **Dynamic otherwise:** at entry, a `mut` buffer is compared by identity with
  every other buffer argument of a shallow type — one i64 compare per pair —
  and a match traps with a message naming the call. This is veri's `blit`
  dispatcher, promoted from a library convention to a language guarantee.

After entry, "`dst` does not alias `src`" is a fact both the vectorizer and a
verifier may assume: it cannot be false, because the program would have
trapped. That satisfies "never silently wrong" without an alias analysis.

Unannotated parameters keep today's semantics (arrays stay shared and
mutable). Whether writes through a *non*-`mut` buffer parameter should warn is a
later ratchet, not part of this slice.

### A4. `consume`: Bend's usage map, locally

The only thing global affinity would buy vibe is **static** uniqueness —
Perceus already frees at last use. So affinity is applied only where it pays:
to a binding passed to a `consume` position.

The checker is Bend's, and vibe already computes the counts:

- quantities {0, 1, ω}; sequential uses add; branches join by **max**;
- a binding passed to a `consume` position must have quantity 1 counted from
  that point on; any later use is
  `xs was consumed at 12:9 by finish(); pass Array::copy(xs) there to keep using it`.

Statically unique means: freshly allocated in this function, and every owning
use so far is a `consume`. For such a value:

1. constructor reuse (ADR-0092) can skip the run-time `rc == 1` test;
2. `TaskGroup::spawn` can move the value into the task instead of making the
   deep-copy snapshot ADR-0068 specifies. `pl-survey-2026-07.md` already names
   this as the intended use of uniqueness.

### A5. Formalization, tied to the implementation

A small calculus in `formal/`: first-order functions, a heap with reference
counts, shallow buffers, and the three modes. Three theorems:

- **T1 (borrow).** A call whose `borrow` arguments pass the check leaves those
  arguments' reference counts unchanged and retains no reference to them. So
  eliding the caller's dup and the callee's drop is sound.
- **T2 (consume).** After a `consume`, the binding is dead on every path, so
  ownership moves exactly once: no double drop, no use after free.
- **T3 (exclusivity).** A call admitted by the static-plus-dynamic check has
  disjoint `mut` footprints. Writes through the `mut` parameter do not change
  any value readable through another parameter (a frame lemma).

Two parts of the practice matter as much as the theorems:

- **Oracle, not just a proof.** The checker in the model is executable. A fixture
  corpus is classified by both the Lean checker and the selfhost
  (`vibe rc-classify` plus a new mode query), and the TSVs are diffed in the
  same way `formal/check-oracle.sh` and `formal/examples/selfhost-call-oracle-test.sh`
  already do for call typing. That diff is what keeps this model from becoming
  a second Bend `bend.lean`.
- **Negative witnesses.** A deliberately broken checker must admit a concrete
  unsound program: one variant drops the escape rule, another drops the
  identity check. `formal/` already keeps such witnesses for the Error policy.

State the gap honestly as well: the model does not cover codegen. The claim
"the emitted dup and drop sequence realizes T1" is a differential and
shadow-liveness (`VIBE_RC=shadow`, ADR-0062) obligation, not a theorem.

## Part B — a vectorizable kernel subset

### B1. What the target allows

- `v128` is the only vector width: 16×i8, 8×i16, 4×i32 / f32, 2×i64 / f64.
  Mojo's `simd_width_of[target]` collapses to `128 / bits(T)`.
- Relaxed SIMD is **excluded**: its results depend on the implementation, and it
  is still behind a flag in Safari.
- Flexible vectors are dormant at phase 1, so nothing length-agnostic is
  designed for.

### B2. What vibe's representation allows

- `Array[Int]` slots are tagged `n << 1`, and **addition is tag-transparent**:
  `i64x2.add` over raw slots is correct with no untag, and it wraps at exactly
  the 63-bit boundary ADR-0105 specifies. Multiplication needs one operand
  untagged. Comparisons preserve order. `bench/bench_simd_int_column.vibe`
  measured a 6.0× speedup for the tagged 2-lane sum over the loop, and 14.7× for
  a packed i32 column. Some of the first number is loop overhead, not SIMD.
  As simd-api-design.md warns, the honest baseline is a native builtin, not a
  vibe loop.
- `Array[Double]` elements are heap-boxed (#510), so they **cannot** be a
  vector source. `Double` kernels need an `F64Column`.
- So the order is: `Array[Int]` first (it exists), then the packed columns from
  Layer 3 of simd-data-structures.md (`I32Column`, then `F64Column`; `F32Column`
  is deferred, see B6).

### B3. The subset: a pure lane-wise lambda given to a column combinator

vibe does not vectorize loops. It vectorizes **combinators** whose function
argument lies in a checkable subset. This is Mojo's `vectorize` with the
compiler, not the user, writing the width-generic closure:

```vibe skip
// proposed
let ys = I32Column::map(xs, (x) -> { if x < 0 { 0 - x } else { x * 3 + 1 } })
let n  = I32Column::count(xs, (x) -> { x >= lo && x < hi })   // lo, hi captured scalars → splat
let s  = Array::sum_int(ints)                                  // reduction, B5
```

A lambda is in the kernel subset when **all** of these hold. Each is a syntactic
or already-computed fact, so the check is a whitelist and never needs an
analysis:

1. its parameters and captures are scalars of the column's element type (a
   captured scalar becomes a `splat`);
2. its body uses only `+ - *` (wrapping), `& | ^ ~`, shifts by a constant,
   comparisons, `min` / `max` / `abs`, literals, `let`, and `if` whose two
   arms are themselves in the subset (lowered to `v128.bitselect`);
3. it **makes no calls** except to functions whose bodies are in the subset
   (these are inlined). That excludes every mutating builtin. The effect row
   is not enough here: `Array::set` carries no effect in vibe;
4. it does not allocate (the `#zero_alloc(strict)` machinery answers this);
5. it is non-recursive and has no early `return`.

Division, and anything else without a lane instruction, is outside the subset.
Such a kernel stays scalar and is still correct.

### B4. The rule that keeps narrowing honest

For an `I32Column`, the lambda is written over `Int` (63-bit), but the lanes are
32 bits wide. When do they agree? Truncation modulo 2³² is a **ring
homomorphism** from ℤ/2⁶³: for `+ - * & | ^ <<`, the low 32 bits of the 63-bit
result equal the i32 lane result. Comparisons, `min` / `max`, `>>` and `abs`
are **not** preserved: `(a + b) > c` can differ once `a + b` leaves the i32
range.

Hence:

> order-sensitive operations (`< <= > >= == != min max abs >>`) may take only
> values loaded from the column, captured scalars proven in range, or
> literals; ring operations may take anything in the subset.

A kernel that breaks this rule stays scalar, and under `#vectorize` it is a
diagnostic that points at the offending comparison. The rule is one lemma to
prove (B7), and it is exactly the case a naive vectorizer gets silently wrong.

What happens at the output is a decision for the column API, and the lowering
must reproduce it. If `I32ColumnBuilder::push` **traps** on a value out of i32
range, the vector kernel has to compute in 2×i64 lanes and check the range, or
stay scalar. A kernel that wraps where the scalar code traps is precisely the
silent-wrong case. The recommendation is to make trapping the default and to
provide an explicit `map_wrapping` whose name states the contract.

### B5. Reductions need an algebra, not a hope

A vector reduction computes one partial fold per lane and then combines the
lanes. That is a chunked, reordered fold. It is valid only when the operation is
associative and commutative, which is the lemma veri's `algebra` package proves
and backs with a negative control on subtraction.

| reduction | vectorize? | why |
|---|---|---|
| `Int` / i32 wrapping sum, product, `& | ^` | yes | a commutative ring / monoid under wrap |
| `Int` / i32 `min`, `max`, `count` | yes | associative, commutative, idempotent |
| `Double` `min` / `max` | yes, with wasm `f64.min` semantics (NaN propagates, `-0 < +0`) | associative and commutative as specified |
| `Double` sum | **no**, not by default | not associative, so reordering changes the result |
| `Double` sum, explicitly | only as `F64Column::sum_unordered` | the name carries the contract |

### B6. Lowering and exact parity

The lowering has the shape of Mojo's `vectorize`: a main loop at width
`128 / bits(T)`, and a scalar tail that runs **the same lowered lambda at width
1**. Lane-wise maps are then equal to the scalar loop by construction. Two
floating-point caveats remain:

- NaN payloads are already nondeterministic for scalar wasm float operations, so
  vectors add no new nondeterminism there. Canonicalization, if vibe ever adds
  it, has to cover both paths.
- `F32Column` is deferred. A chain of `f32` operations is not equal to the same
  chain computed in `Double` and rounded once at the end, so an `F32` kernel
  would need a real `Float32` scalar type first.

Aliasing, where Part A meets Part B:

- `map` / `zip_with` that **produce a new column** cannot alias anything, and
  frozen columns are immutable, so they need nothing.
- an **in-place, same-index** kernel (`dst[i] = f(src[i])`) is correct even when
  `dst` and `src` are the same object, because each lane reads its element
  before it writes it;
- a **shifted-index** kernel (stencils, `copy_within`-like moves) needs
  `mut dst` with exclusivity (A3). That is the only place vectorization
  requires the borrow subset.

### B7. `#vectorize` is a checked assertion

Without an annotation, the compiler vectorizes a combinator call whenever its
lambda is in the subset, and says nothing. That is safe because the result is
identical (B6). With an annotation it must succeed, or report why:

```vibe skip
// proposed
#vectorize
fn clamp_all(xs: I32Column, lo: Int, hi: Int) -> I32Column {
  I32Column::map(xs, (x) -> { max(lo, min(hi, x)) })
}
```

```text
error: clamp_all is marked #vectorize, but the lambda at 4:27 stays scalar:
  `min(hi, x)` compares a captured Int that is not known to fit in i32.
  Add `requires: lo >= -2147483648 && hi <= 2147483647` to the where clause,
  or clamp inside the column's range.
```

This answers the Bend lesson directly: the annotation is a checked contract, like
`#zero_alloc`, not a hint the checker never reads. A line-oriented query
(`vibe vectorize-report file.vibe`, which prints `FN LINE:COL vectorized i32x4`
or `FN LINE:COL scalar REASON`) follows the policy that the CLI is the LLM's
IDE.

### B8. Verification of the lowering

Follow veri's four parts:

1. **Lemmas** (Lean, in `formal/`): the map lowering with its width-1 tail equals
   the scalar loop; truncation is a ring homomorphism (B4); a chunked reordered
   fold equals the sequential fold for associative and commutative operations
   (B5).
2. **Differential tests**: every vectorized kernel in the test corpus is also
   compiled with vectorization off, and both are run on generated inputs
   (`lib/@vibex/quickcheck`, with fixed seeds). The inputs include lengths
   `0 .. 2W + 1` to cover every tail boundary, and values at the i32 and i63
   extremes.
3. **Negative controls**: a deliberately wrong lowering must fail the
   differential gate. Two such lowerings are vectorizing a comparison after an
   overflowing add, and reassociating a `Double` sum. This is the repository's
   rule that a gate is trusted only once it has been shown to fail (#2248).
4. **A correspondence table** in the eventual ADR. Its last column states,
   operation by operation, whether equality is **proved**, **tested**, or
   **not claimed**.

### B9. What SIMD is not

SIMD is not parallelism. Bend's GPU findings apply to any "run this wide"
annotation. Parallelism must be visible and checked, and balance is the
program's problem. vibe's thread-level story stays ADR-0068: shared-nothing
tasks, with `Parallel::map` over `Send` values. The only link to this proposal
is A4, where a statically unique column is moved into a task instead of being
deep-copied.

## 2. Contracts: where-clause Phase 3 on the same subset

The two parts above hand a verifier exactly the preconditions MoonBit lacks:

- `old(e)`: design it now as the pre-state binder in `ensures`, before any
  mutating contract is written (veri could not state "unchanged outside the
  written range");
- inside a function, a `mut` parameter is known not to alias the other
  parameters (A3), so there is no Why3-style alias rejection to work around.

The Phase 3 shape follows Vx: small, local, decidable obligations. There is
one query per function in QF_BV plus arrays (`Int` as `(_ BitVec 63)`, which
matches ADR-0105 wrapping), and SMT-LIB goes directly to Z3. A satisfiable
query returns a counterexample in source terms. `unknown` or a timeout counts
as unproved, never as proved. Any trusted-boundary marker (an assumed
contract, like `#zero_alloc(assume)`) needs a `--deny-assume` mode that fails
the run, because Bend's `@unsafe` shows that taint without a gate is not safety.

## 3. Slices, in dependency order

Each slice is shippable alone, and none changes the meaning of unannotated
code.

| # | slice | depends on | new surface |
|---|---|---|---|
| 1 | declared `borrow`, checked against the inferred mask; written to `index.vpkg` | — | parameter mode |
| 2 | Lean model + executable oracle for `borrow` / escape (T1), with a negative witness | 1 | none |
| 3 | `mut` exclusivity on shallow buffers: static place check + entry identity check (T3) | 1 | parameter mode |
| 4 | `consume` with the local usage map; static uniqueness skips the reuse `rc == 1` test and turns spawn into a move (T2) | 1 | parameter mode |
| 5 | i32x4 / i64x2 / f64x2 arithmetic and compare emitters in `codegen/wasm_emit/simd.vibe` | — | none |
| 6 | kernel-subset recognizer + lowering for `Array[Int]` `map` / `count` / `sum` (2×i64, tag-transparent) with the differential gate | 5 | none |
| 7 | `I32Column` (simd-data-structures Layer 3) with the B4 narrowing rule and trap-by-default output | 6 | a type |
| 8 | `#vectorize` + `vibe vectorize-report` | 6 | annotation, query |
| 9 | `F64Column` with `min` / `max` and `sum_unordered` | 7 | a type |
| 10 | shifted-index in-place kernels under `mut` exclusivity | 3, 7 | none |
| 11 | `where` Phase 3 on the QF_BV + arrays subset, with `old(e)` | 3 | `old`, `vibe prove` |

Slices 1–4 and 5–8 are independent tracks, so they can proceed in parallel.
Slice 10 is the one point where they meet.

## 4. What not to build

- **Rust-style reference types and lifetime parameters.** Second-class modes
  cover the cases vibe needs, and lifetimes would be the first concept in the
  language whose diagnostics cannot lead with a simple edit.
- **Global affinity.** Bend measured what it costs: arrays become sequential
  and there are five expressiveness walls. Perceus already provides the memory
  benefit that affinity would have bought.
- **A first-class vector value.** This was decided against on measurement
  (#2342), and nothing here needs one.
- **Relaxed SIMD in the default lane**, or any reassociating `Double`
  reduction behind a heuristic.
- **General loop auto-vectorization** of `while` loops over `let mut`. The
  combinator subset is decidable by a whitelist; loop vectorization needs
  dependence analysis, and every failure of that analysis is a silent
  performance cliff. Revisit it only if the combinator subset proves too
  narrow in practice.
- **A GPU or "parallel" annotation that the type system does not check.**

## 5. Open questions

1. Spelling: `borrow` / `mut` / `consume` as prefix parameter modes, or a
   suffix form like the labeled `x~`? `mut` already means "mutable field" in
   structs (ADR-0052). The two meanings are related but not identical.
2. Should a declared `borrow` be *required* on exported functions once slice 1
   lands, so that the package ABI stops depending on a whole-program fixpoint?
3. Does `I32Column` out-of-range output trap (recommended) or wrap? This has to
   be decided before slice 7, because the vector lowering must reproduce
   whichever is chosen.
4. Should the wasm-gc lane get these kernels at all? Inline wasm is
   linear-only today, but combinator lowering is emitted by the compiler and
   could target both lanes.

# Borrowing and vectorization for vibe: a designed-in subset

Proposal, 2026-09-23. Not an ADR. It draws on the notes in this directory
([bend.md](bend.md), [mojo.md](mojo.md), [vx.md](vx.md),
[moonbit-veri.md](moonbit-veri.md)). It asks one question: **if vibe designs
these in now, can it meet the constraints by restricting them to specific
patterns, rather than by adopting a full borrow checker or a general
auto-vectorizer?**

Short answer: yes, for both, and the two subsets meet at one rule — **a
mutable buffer argument does not alias any other argument**. That rule is what
a verifier needs (veri's blit split) and what an in-place vector kernel needs.
It is **not** what Perceus needs in order to drop its run-time `rc == 1` test.
Exclusivity constrains only what the *callee* can reach. The caller may still
hold another reference (`let b = a; f(mut a)`), so the count can exceed one.
Only A4's static uniqueness justifies skipping that test.

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
| `borrow_ret`, `view_ret`, `scalar_ret` sets | `runtime/rc_query.vibe` (`vibe rc-classify`) | whether a result's **root** aliases a parameter (not its interior; A2) |
| consume counting | `md_consume_count` in `common_analysis.vibe` | the usage map Bend uses, mostly computed (loop and closure bodies count once; A4 needs ω there) |
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
| `borrow` | read; pass it only to positions that do not write | no transfer dup, no drop; *unchanged contents* only under T1′'s premise (A5) | consume count = 0, no escape, and no write through it (A2) |
| `mut` | write through it; never consume it or let it escape | the argument does not alias any other argument, and is not retained | exclusivity (A3) plus the same zero-consume and escape checks as `borrow` (A2) |
| `consume` | keep, return, store, reuse in place | the binding is dead after the call | usage map at the call site (A4) |

Unannotated code does not change. A mode is an opt-in promise that the checker
verifies and that the ABI can then rely on across a package boundary.

**Modes are declared only on top-level `fn` parameters, and a function that
declares one is called only directly.** A lambda cannot declare a mode, and a
moded `fn` cannot be taken as a value: a function type carries no modes, and
if it did, the mode would stop being second-class. The restriction matters for
`mut` in particular. A local closure could capture the very buffer that is
passed to its `mut` parameter, and then read the capture while writing through
the parameter. The callee is neither an argument nor a global, so none of A3's
checks would see that alias. A top-level `fn` captures nothing, and its reach
into globals is covered by A3's environment rule.

**Every moded `fn` has a transitive effect row that is empty or `Exception`
only**, whichever modes it declares. Resumable operations break every mode
separately:
- A handler arm runs in the middle of the call and can capture another alias
  of a buffer (A3, and T1′ for `borrow`).
- A handler can **store `resume` and return without resuming**. First-class
  continuations are part of the language (see the cheatsheet's section on
  handlers). A continuation suspended inside the callee keeps its frame, and
  therefore every `borrow` and `mut` parameter, alive past the call. That is
  an escape that the region checks cannot see, because it happens in no
  expression the callee wrote. T1 itself becomes false: the reference is
  retained, and the caller's elided dup leaves it dangling.

Raising `Exception` abandons the frame, so the *frame* cannot outlive the
call. Its **payload** can, though. `Exception[E]` carries an arbitrary value,
so `throw(xs)` hands `xs` to the caller's handler. The throw payload is
therefore an escape position, on the same footing as a return value (A2): a
borrow-derived value or a `mut` parameter may not appear in it, nor in any
other operation payload. A later slice can
re-admit resumable effects together with a call-site check that no enclosing
handler captures an alias or stores the continuation. Until then the rule is
one line, and it applies to all three modes.

### A2. `borrow` is a region the length of the call

A `borrow` parameter is exactly a region token whose extent is the call. The
escape checks vibe already runs for `region r { }` and `TaskGroup::run` —
return, outer binding, container write, closure capture, plus a `throw` payload (A1) — are the escape
checks a borrow needs. Reusing them avoids a second escape analysis, and it
closes one of the documented holes on the way: a `borrow` is a parameter, not
a generalized `let`, so the "leak through a generalized local" gap does not
apply to it.

**The inferred mask is not enough on its own: it answers "is this consumed",
not "is this written".** The consume analysis classifies `Array::set`,
`Array::push`, `Bytes::set` and `FixedArray::set` as borrowed positions,
because a mutator does not take ownership. So
`fn f(borrow xs: Array[Int]) { Array::set(xs, 0, 1) }` has consume count 0 and
no escape, and a check built only on the mask would accept it. That would let
a write bypass the `mut` exclusivity contract (A3). A declared `borrow`
therefore needs a separate **write check**:

- the check applies to every **borrow-derived** value, not only to the
  parameter's own name. The definition is **closed by default**: it is not a
  list of expression forms that propagate. A value is borrow-derived if
  **either** of these holds:
  - it is the parameter itself;
  - it is any expression with a borrow-derived subexpression, **unless its
    type is buffer-free** (A3's allow-list).

  So taint flows through every form that can carry a buffer without being
  named, including forms added to the language later: projections (`h.buf`,
  `t.0`), element reads, pattern variables, `if` / `match` results, tuple /
  struct / enum / `Option` construction (`Holder::{ buf: xs }`), and locals
  bound by `let` or assigned by `let mut`. The only exception is the one that
  cannot carry a buffer at all. Call results follow the same rule: a call
  with a borrow-derived argument yields a borrow-derived result unless the
  result type is buffer-free. The existing `borrow_ret` / `view_ret`
  summaries (`vibe rc-classify`) **cannot** clear it. They describe who owns
  the result's *root*, and `mrv_fresh` in
  `codegen/common_analysis/common_analysis.vibe` classifies a tuple, array or
  record constructor as fresh regardless of what its children alias. So
  `wrap(xs) = Holder::{ buf: xs }` has a fresh root and an aliased interior,
  and `Array::set(wrap(xs).buf, 0, 1)` would mutate the borrowed buffer.
  Refining a result toward untainted needs a new **deep-alias summary**,
  "no buffer reachable from the result comes from argument *i*", computed
  and imported like the write summary. Until that summary exists, the rule
  does not refine at all.

  This is a flow-insensitive taint over one function body, which is
  conservative and cheap. Earlier drafts listed the propagating forms instead,
  and review found a missing form three times: a projection, a call result,
  and an aggregate constructor
  (`let h = Holder::{ buf: xs }; Array::set(h.buf, 0, 1)`). An allow-list of
  *exemptions* cannot be incomplete in the unsafe direction;
- a borrow-derived value is never the buffer argument of a mutating builtin.
  The registry already knows which builtins write; `md_is_borrow_arg0_call`'s
  list is the starting point, and the rule is the opposite one: a mutator is
  a write, whatever its ownership class. It is also never the target of a
  `mut` struct-field assignment (ADR-0052);
- a borrow-derived value is never passed to a `mut` position;
- a borrow-derived value is never passed to a `consume` position either, and
  doing so counts as an escape. The `borrow` owns no reference to transfer,
  so `fn f(borrow h: Holder) { sink(consume h.buf) }` would let `sink` retain
  a buffer nobody gave it. That is a double drop or a use after free;
- a borrow-derived value is passed to an unannotated position only if that
  callee's per-parameter **write summary** says "does not write". Summaries
  attribute writes to the **root** parameter, so a callee that writes
  `p.buf` reports a write to `p`. The summary is computed and
  imported the same way `#zero_alloc` summaries are (ADR-0091). An unknown
  callee (a function value, a missing summary) counts as a writer.

Checking a declared `borrow` this way is the first slice, and it changes no
code generation: it only turns an inference into a contract. The contract is
the payoff. The borrow fixpoint is whole-program today, and
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
- **No hidden paths to the buffer.** Identity comparison only sees arguments
  that *are* buffers. It misses a buffer *reachable through* another argument:
  `f(xs, Holder::{ buf: xs })` passes both checks above, yet a read through
  `holder.buf` sees the write through `xs`. So, in a call with a `mut`
  argument, every other argument must have a **buffer-free type**. That is
  defined as an **allow-list**, not by excluding known offenders:
  - scalars and `String`;
  - tuples and `Option` of buffer-free types;
  - structs and enums whose declaration is visible and whose every field or
    payload is buffer-free, checked through type aliases.

  Everything else is excluded *by construction*, rather than by enumeration:
  shallow buffers, function types (a closure may capture the buffer), type
  variables (they could be instantiated to either), and **opaque or bodyless
  nominal types**. An `opaque type` from another package can hide an
  `Array[Int]` behind its methods, and its contract does not show the fields.
  A package contract may later certify an opaque type as buffer-free
  explicitly; until then it does not qualify. The only other permitted
  arguments are shallow buffers themselves, which the identity check covers. Anything else is a compile error that
  names the edit: pass the buffer directly, or copy it first.
- **No reach through the environment either.** The callee must not read any
  top-level binding whose type is **not buffer-free**, either directly or
  through a callee. That covers a bare buffer global (`f(mut table)` reading
  `table` again), and also an aggregate that holds one (`f(mut holder.buf)`
  while `f` reads `holder.buf` through the global `holder`) and a top-level
  closure whose captures reach one. This is the same recursive predicate as
  the argument rule, applied to globals. It needs its own interprocedural
  **reach summary** ("may read a non-buffer-free global"), computed and
  imported like the A2 write summary. The write summary alone does not
  record reads.
- **No reach through effect handlers.** A handler is supplied dynamically by
  the caller, and its arms can capture the very buffer passed as `mut`. If the
  callee performs a resumable algebraic operation during the call, that arm
  runs *inside* the call and can read the capture. Neither the argument list
  nor the reach summary would see it. **Every resumable operation can be
  handled by user code**, and that includes the built-in ones:
  `fixtures/async_sleep_handler_discharge_test.vibe` intercepts
  `Async::Suspend` with an arm that writes a captured `Array` and then
  resumes, and `fixtures/effect_handle_resume_test.vibe` shows that
  `Console::ReadLine`, a host capability, is intercepted by a user handler in
  the same way. So the transitive effect row of a function with a
  `mut` parameter must be **empty, or contain only `Exception`**. Raising
  abandons the call, so an `Exception` handler that reads the buffer runs
  after the call's frame has ended. `Array` not being `Send` does not help
  here, because no second task is involved: the handler runs on the same
  stack, in the middle of the call.

  The alternative, checking the captures of the handler arms that enclose
  the call site, is a later slice. It would re-admit `Async` and capability
  operations whenever no enclosing arm captures a non-buffer-free value.

With those rules the frame of a `mut` call is exactly its argument list, and
the entry identity check covers the only aliasing the argument list can
express. After entry, "`dst` does not alias anything else this call can reach"
is a fact both the vectorizer and a verifier may assume: it cannot be false,
because the program would either have been rejected or trapped. That
satisfies "never silently wrong" without a general alias analysis. The price
is expressiveness, paid deliberately: a `mut` call cannot also take a struct
that holds buffers. It can still take that struct's buffers as separate
arguments.

Unannotated parameters keep today's semantics (arrays stay shared and
mutable). Whether writes through a *non*-`mut` buffer parameter should warn is a
later ratchet, not part of this slice.

### A4. `consume`: Bend's usage map, locally

The only thing global affinity would buy vibe is **static** uniqueness —
Perceus already frees at last use. So affinity is applied only where it pays:
to a binding passed to a `consume` position.

The checker is Bend's, and vibe already computes most of the counts:

- quantities {0, 1, ω}; sequential uses add; branches join by **max**;
- **a use inside a body that can run more than once is ω**. That means the
  body of a `while` or `for`, and the body of any lambda, because a closure
  may be called repeatedly. So consuming a binding defined *outside* such a
  body is an error: `while again() { finish(xs) }` would transfer the same
  ownership on the second iteration, which is a double drop or a use after
  free. A binding defined *inside* the body is fresh on each iteration and
  unaffected. The fix the diagnostic suggests is to rebind inside the body,
  or to move the consume after the loop. `md_consume_count` cannot be reused
  unchanged: its `EWhile` / `EForIn` / `EFn` arms count the body once, which
  is right for dup/drop placement and wrong for this check;
- a binding passed to a `consume` position must have quantity 1 counted from
  that point on; any later use is
  `xs was consumed at 12:9 by finish(); pass Array::copy(xs) there to keep using it`.
- **within one call, a consumed argument shares its root with no other
  argument**. The other arguments of the same call are evaluated before the
  callee runs, so "later use" does not cover them. A `borrow` or `mut`
  argument holds no reference of its own, because its dup was elided. So in
  `bad(a, a)` against `fn bad(borrow xs, consume ys) { sink(ys); Array::length(xs) }`,
  `xs` is read after `sink` has dropped the only reference, which is a use
  after free. The same happens with a projection (`bad(h.buf, h)`). The
  check therefore compares the *roots* of the argument places: if any other
  argument's place starts at the root of a `consume` argument, the call is
  rejected, and the diagnostic suggests passing a copy. Distinct bindings
  that happen to alias the same object are fine: each holds its own counted
  reference, so the consume releases only one of them.

Statically unique means: freshly allocated in this function, and every owning
use so far is a `consume`. For such a value:

1. constructor reuse (ADR-0092) can skip the run-time `rc == 1` test. Reuse
   repurposes only the root cell, and the decomposition already transfers each
   child, so uniqueness of the root is the whole requirement;
2. `TaskGroup::spawn` can move the value into the task instead of making the
   deep-copy snapshot ADR-0068 specifies, **but only for a pointer-free
   buffer**: `Array[S]` where `S` is an immediate (`Int`, `Bool`, `Char`,
   `Unit`), `Bytes`, or a packed column. "Scalar" is not enough.
   `Array[Double]` holds heap boxes (#510), and `String` is a heap object. After
   `let d = 1.5; let xs = [d]`, moving a root-unique `xs` would leave the
   box reachable from the caller's `d` and from the child task at once,
   with non-atomic reference counts on both sides. Static
   uniqueness is a fact about the *root* allocation. After
   `let inner = [1]; let outer = [inner]`, `outer` can be fresh and consumed
   exactly once while the caller still holds `inner`. Moving `outer` would let
   the caller mutate what the child task reads. Deeper graphs keep the deep
   copy until uniqueness is established transitively, for every reachable
   object. That is a stronger analysis and a later slice.
   `pl-survey-2026-07.md` already names the shallow case as the intended use
   of uniqueness.

   Even a pointer-free unique buffer is **not** movable by this proposal
   alone. Two more premises are needed, and both belong to a later slice:
   - **A transferable arena.** On the native/WASI backend every worker has
     its own `Store`, `Instance` and linear memory
     ([concurrency.md](../../internal/design/concurrency.md), native/WASI
     backend policy), so an `Array`'s address means nothing in the child.
     The concurrency contract already allows a move only when every
     reachable allocation lives in one transferable arena. On such a backend
     the move is a copy of the arena, or it stays the deep copy. A pointer
     handoff is legal only on a single-heap backend (today's cooperative
     scheduler).
   - **A one-shot consuming capture for the spawn closure.**
     `TaskGroup::spawn` takes a closure, and A4 counts a use inside a lambda
     as ω. `Array` and `Bytes` are also not `Send`, so the existing spawn
     capture check rejects them. A move needs a rule that a closure passed
     *directly* to `spawn` runs exactly once, so its captures may be
     `consume`d, and it needs matching `Spawnable` handling.

   Until both land, spawn keeps ADR-0068's deep-copy snapshot, and T2's
   statement about spawn is a design target, not a claim.

### A5. Formalization, tied to the implementation

A small calculus in `formal/`: first-order functions, a heap with reference
counts, shallow buffers, and the three modes. Three theorems:

- **T1 (borrow).** A call whose `borrow` arguments pass the check leaves those
  arguments' reference counts unchanged, retains no reference to them, and
  performs no write **through** them. Eliding the caller's dup and the
  callee's drop needs only this ownership half, so it is sound whatever else
  aliases the argument.
- **T1′ (borrow frame).** The stronger claim, that the *contents* are
  unchanged during the call, is a separate theorem with an extra premise: no
  other writable path of the call reaches the same buffer. `borrow` alone
  cannot promise this. In `fn f(borrow xs: Array[Int], ys: Array[Int])
  { Array::set(ys, 0, 1) }`, the call `f(a, a)` writes `a` through `ys`, and
  nothing about `xs` is violated. T1′ holds when every *other* parameter is
  `borrow`, buffer-free, or `mut` (A3 already makes a `mut` buffer disjoint
  from every other argument, `borrow` ones included), when the callee's
  write summary reaches no non-buffer-free global, and when the callee's
  transitive effect row is empty or `Exception` only. The last premise is the
  same one A3 imposes on `mut`, for the same reason: a handler arm that
  captures another alias of the buffer can write it while the call is
  suspended in a resumable operation, even for `f(borrow a)` with no other
  parameters at all. A verifier or optimizer
  that wants "unchanged contents" must check those premises at the call. A
  call with an unannotated writable buffer parameter does not get T1′,
  and the diagnostic for a `#vectorize` or a contract that needs it says to
  annotate that parameter.
- **T2 (consume).** After a `consume`, the binding is dead on every path,
  including every later iteration of an enclosing loop and every later call of
  an enclosing closure, so
  ownership moves exactly once: no double drop, no use after free.
- **T3 (exclusivity).** A call admitted by the static-plus-dynamic check,
  with its buffer-free argument and environment rules, has disjoint `mut`
  footprints. Writes through the `mut` parameter do not change
  any value readable through another parameter (a frame lemma).

Two parts of the practice matter as much as the theorems:

- **Oracle, not just a proof.** The checker in the model is executable. A fixture
  corpus is classified by both the Lean checker and the selfhost
  (`vibe rc-classify` plus a new mode query), and the TSVs are diffed in the
  same way `formal/check-oracle.sh` and `formal/examples/selfhost-call-oracle-test.sh`
  already do for call typing. That diff is what keeps this model from becoming
  a second Bend `bend.lean`.
- **Negative witnesses.** A deliberately broken checker must admit a concrete
  unsound program. One variant drops the escape rule, one drops the
  `borrow` write check, one checks writes on the parameter name only and
  not through projections, one drops the identity check, one drops the
  buffer-free-argument rule, one checks only bare-buffer globals, one
  counts a loop body's consume once, one admits a `mut` call through a
  capturing closure, one ignores call results in the borrow taint, one ignores aggregate construction in it, one trusts a root-only alias summary for a call result, one claims T1′ for a call that also passes the buffer to an unannotated writable parameter, one lets a borrow-derived value reach a `consume` position, one elides `rc == 1` on the strength of `mut` exclusivity alone, one claims T1′ for a `borrow` callee that performs a resumable effect, one moves a root-unique but non-shallow value into a task, one lets a `mut` parameter escape by return or capture, one lets a stored continuation retain a `borrow` frame, one throws a borrowed value as an exception payload, one passes the same root to `borrow` and `consume` in one call, one computes the 2×i64 fallback untagged, one accumulates an `Int`-valued `I32Column::sum` in i32x4 lanes, one vectorizes `dst[i] = dst[i - 1]` in place, one moves an `Array[Double]` into a task, one hands a buffer pointer to a worker on a separate linear memory, one canonicalizes the NaN of a pass-through kernel, one lets
  an opaque type count as buffer-free, and one lets a `mut` callee perform a
  user effect whose handler captures the buffer, and one lets it perform
  `Async` under a user handler that does the same. `formal/` already keeps such witnesses for the Error policy.

**Why the model has to come first.** Review of this document found the
same class of hole again and again, each one a path the prose rules had not
enumerated. Thirty-four findings in seventeen rounds so far:
- aliases hidden in an aggregate argument, in an aggregate global, and in a
  closure callee;
- aliases reached through an effect handler (three times: user effects, then `Async`, then under a `borrow`) or an opaque type;
- writes made through a projection, a call result (twice), and a constructed aggregate;
- a consume inside a loop, and a consume whose root is also borrowed by another argument of the same call;
- a caller-created alias between a `borrow` argument and a writable one;
- a borrow-derived value passed to `consume`;
- `rc == 1` elision justified by `mut` exclusivity, which ignores the caller's own references;
- a task move justified by root-only uniqueness;
- a `mut` parameter escaping by return, a `borrow` frame retained by a stored continuation, and a borrowed value escaping as an exception payload;
- a vector fallback that wraps at 2⁶⁴ instead of 2⁶³, and a reduction accumulator that wraps at 2³²;
- NaN canonicalization applied to a bit-exact pass-through;
- a loop-carried dependence inside one buffer, which exclusivity does not see;
- a task move of a buffer whose elements are heap boxes, one across isolated worker heaps, and one through a closure capture that A4 counts as ω.

Enumerating exceptions in English does not converge. What does converge is an
executable model whose checker is diffed against the implementation, together
with a corpus that grows by one negative witness per hole found. Those
findings are the initial corpus. So slice 2 (the model) precedes slice 3
(exclusivity), and no mode lands in the compiler without its witnesses.

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
  the 63-bit boundary ADR-0105 specifies. The other operations are not all
  tag-transparent, and each one needs its own lowering:

  | operation | tagged-lane lowering |
  |---|---|
  | `+ - & \| ^`, negation, comparisons | as is (the tag bit is 0 on both sides and stays 0; order is preserved) |
  | `*` | untag one operand (`i64x2.shr_s` by 1) first |
  | `<< c` | as is, for `c` in `[0, 62]` |
  | `>> c` | `i64x2.shr_s` by `c`, then clear bit 0, which receives a value bit |
  | `~` | **xor with tagged(-1) = `-2`, not `v128.not`**. A plain not sets the tag bit and produces a malformed `Int`, the same trap the scalar lowering documents in `AGENTS.md` (`~0` must be `-2`, not `-1`) |
  | literals, captured scalars | splat the tagged value |

  Each row is a lemma in B8, and each has a negative control. A lowering that
  uses `v128.not` for `~`, or that omits the bit-0 clear after `>>`, must fail
  the differential gate. `bench/bench_simd_int_column.vibe`
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
let n  = I32Column::count(xs, (x) -> { x >= lo && x < hi })   // lo, hi: captured, splat; must be proven in i32 range (B4)
let s  = Array::sum_int(ints)                                  // reduction, B5
```

A lambda is in the kernel subset when **all** of these hold. Each is a syntactic
or already-computed fact, so the check is a whitelist and never needs an
analysis:

1. its parameters and captures are scalars of the column's element type (a
   captured scalar becomes a `splat`);
2. its body uses only `+ - *` (wrapping), `& | ^ ~`, shifts whose count is a
   **literal smaller than the lane width** (B4), comparisons, `&&` / `||` /
   `!` on comparison results (lowered to `v128.and` / `v128.or` /
   `v128.not` on lane masks; both sides are evaluated, which is sound only
   because every operation in the subset is total, item 3), `min` / `max` /
   `abs`, literals, `let`, and `if` whose two arms are themselves in the
   subset (lowered to `v128.bitselect`), and it obeys the range rule of B4;
3. it **makes no calls** except to functions whose bodies are in the subset
   **and that carry no `where` contract** (these are inlined). That excludes
   every mutating builtin. The effect row is not enough here: `Array::set`
   carries no effect in vibe. The contract exclusion exists because `if`
   lowered to `bitselect` evaluates **both** arms on **every** lane. A
   `requires` is an always-on trap (ADR-0064), so
   `if x > 0 { positive(x) } else { 0 }` is safe as a scalar program but
   would trap on the inactive lanes. More generally, every operation in the
   subset must be **total**, meaning it cannot trap on any input. That is
   also why division is excluded, not only for its missing lane instruction.
   Predicating contract checks with the active-lane mask is possible in
   principle, but it is not proposed for a first cut;
4. it does not allocate (the `#zero_alloc(strict)` machinery answers this);
5. it is non-recursive and has no early `return`.

Division, contracted calls, and anything else that can trap or has no lane
instruction are outside the subset.
Such a kernel stays scalar and is still correct.

### B4. The rule that keeps narrowing honest

For an `I32Column`, the lambda is written over `Int` (63-bit), but the lanes are
32 bits wide. When do they agree? Truncation modulo 2³² is a **ring
homomorphism** from ℤ/2⁶³: for `+ - * & | ^ ~`, the low 32 bits of the 63-bit
result equal the i32 lane result, whatever the operands are. Nothing else is
preserved unconditionally, and the exceptions are exactly where a naive
vectorizer is silently wrong:

- **Shifts.** `x << c` is multiplication by 2ᶜ, so it is a ring operation, but
  only while `c` is below the lane width. Wasm's `i32x4.shl` takes the count
  **modulo 32**, so `x << 32` yields `x` in a lane while the scalar `Int`
  result has 32 zero low bits. The count must therefore be a literal in
  `[0, 31]` on i32 lanes. On tagged `Int` lanes (2×i64, where `n` is stored
  as `n << 1`) it must be in `[0, 62]`. A variable count leaves the subset.
- **Order-sensitive operations** (`< <= > >= == != min max >>` and `abs`)
  agree with the scalar code only when their operands already fit in i32.
  `(a + b) > c` differs once `a + b` leaves the range, and so does `abs(a + b)`.
- **`abs` and unary negation do not stay in range.** On a loaded
  `-2147483648`, scalar `abs` gives `2147483648`, while the i32 lane gives
  `-2147483648`. The low bits agree, so feeding the result into ring
  operations is fine, but `abs(x) > 0` answers differently.

So define a **range-exact** value as one that is guaranteed to fit the lane:

- a value loaded from the column;
- a literal in range;
- a captured scalar whose range is proven, for example by a `requires` in the
  enclosing `where` clause;
- `min`, `max`, or `>>` by a literal, applied to range-exact operands.

Results of `+ - * << ~`, `abs`, and negation are **not** range-exact. The rule
is then:

> order-sensitive operations (`< <= > >= == != min max >> abs`) may take only
> range-exact operands; ring operations may take anything in the subset.

A kernel that breaks this rule stays scalar. Under `#vectorize` it is a
diagnostic that points at the offending operation. The rule becomes two lemmas
(B8): truncation is a ring homomorphism, and each order-sensitive lane operation
agrees with its scalar counterpart on range-exact inputs. It is exactly the
case a naive vectorizer gets silently wrong, and the negative controls in B8
include one variant per exception above.

What happens at the output is a decision for the column API, and the lowering
must reproduce it. If `I32ColumnBuilder::push` **traps** on a value out of i32
range, the vector kernel has to compute in 2×i64 lanes and check the range, or
stay scalar. Those lanes must hold the **tagged** representation (`n << 1`)
and use B2's tagged-lane lowering table. The table is not optional here: plain
i64 arithmetic wraps at 2⁶⁴, not 2⁶³. With `x = 1 << 30`, the scalar
`(x * x) * 8` wraps to `0` and the push succeeds, while untagged i64 lanes
produce `-2⁶³` and the range check traps. In the tagged representation,
every intermediate wraps exactly where the scalar `Int` does (ADR-0105), so
the final untag-and-range-check sees the scalar value. A kernel that wraps where the scalar code traps is precisely the
silent-wrong case. The recommendation is to make trapping the default and to
provide an explicit `map_wrapping` whose name states the contract.

### B5. Reductions need an algebra, not a hope

A vector reduction computes one partial fold per lane and then combines the
lanes. That is a chunked, reordered fold. It is valid only when the operation is
associative and commutative, which is the lemma veri's `algebra` package proves
and backs with a negative control on subtraction.

| reduction | vectorize? | why |
|---|---|---|
| `Int` wrapping sum, product, `& \| ^` | yes, in tagged 2×i64 lanes | a commutative ring / monoid under the 63-bit wrap |
| `I32Column::sum` / `product` (result is `Int`) | yes, **widening** each element to a tagged i64 lane (`i64x2.extend_*_i32x4`) and accumulating there | the result is an `Int`, so it wraps at 2⁶³. An i32x4 accumulator wraps a lane at 2³², before the horizontal reduction, and cannot recover the `Int` sum: five `2147483647` elements already disagree. Associativity is necessary but does not make the two rings the same |
| an explicitly i32-wrapping sum (`sum_wrapping_i32`, if ever wanted) | yes, in i32x4 lanes | the name states that the result wraps at 2³² |
| `Int` / i32 `min`, `max`, `count` | yes | associative, commutative, idempotent |
| `Double` `min` / `max` | yes, with wasm `f64.min` semantics (NaN propagates, `-0 < +0`) **and a canonical NaN result in both paths** | associative and commutative on values, but not on NaN payloads: wasm leaves an arithmetic NaN's payload nondeterministic, so reassociating can change which payload comes out. Canonicalizing the result restores bit-exact parity |
| `Double` sum | **no**, not by default | not associative, so reordering changes the result |
| `Double` sum, explicitly | only as `F64Column::sum_unordered` | the name carries the contract |

### B6. Lowering and exact parity

The lowering has the shape of Mojo's `vectorize`: a main loop at width
`128 / bits(T)`, and a scalar tail that runs **the same lowered lambda at width
1**. Lane-wise maps are then equal to the scalar loop by construction. Two
floating-point caveats remain:

- **NaN payloads.** Wasm leaves the payload of an arithmetic NaN
  nondeterministic for scalar and vector operations alike. So "the scalar path
  is already nondeterministic" does not make a vector path bit-exact: the two
  may pick different payloads, and a reordered reduction certainly can. The
  parity contract therefore canonicalizes, **per operation, and only where
  the payload is nondeterministic**. The result of each float arithmetic
  operation (`+ - * /`, `sqrt`, `min`, `max`, and every reduction step)
  that is a NaN is rewritten to the canonical NaN, on **both** paths. That
  costs one compare plus one `bitselect` per vector. Operations that wasm
  defines bit-exactly are *not* canonicalized: loads, stores, lane select,
  `neg`, `abs` and `copysign`. A pass-through kernel such as
  `F64Column::map(xs, (x) -> { x })` therefore keeps its input NaN payloads,
  exactly as the scalar identity loop does. Those payloads are observable
  through the bit-conversion APIs, so canonicalizing them would itself be a
  silent change. The differential gate (B8) compares bit patterns, so it
  checks the canonicalization too. The alternative, a contract that is
  explicitly "equal modulo NaN payload", would be weaker than the rest of this
  document promises, and is not proposed.
- `F32Column` is deferred. A chain of `f32` operations is not equal to the same
  chain computed in `Double` and rounded once at the end, so an `F32` kernel
  would need a real `Float32` scalar type first.

Aliasing, where Part A meets Part B:

- `map` / `zip_with` that **produce a new column** cannot alias anything, and
  frozen columns are immutable, so they need nothing.
- an **in-place, same-index** kernel (`dst[i] = f(src[i])`) is correct even when
  `dst` and `src` are the same object, because each lane reads its element
  before it writes it;
- a **shifted-index** kernel (stencils, `copy_within`-like moves) must
  **never read its destination**. It reads only from a distinct `borrow src`
  and writes only `mut dst`, and A3's exclusivity proves the two disjoint.
  Exclusivity removes *external* aliases, but it says nothing about
  dependences *within* one buffer. `dst[i] = dst[i - 1]` carries a value
  across iterations: the scalar forward loop propagates the first element
  through the whole range, while a vector loop that loads a chunk before
  storing it propagates only at chunk boundaries. An in-place shifted
  kernel therefore stays scalar. Admitting one would need a dependence
  check (the shift's sign and distance against the lane count), which is a
  later refinement. This is the only place vectorization requires the borrow
  subset.

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
  Bound both sides of each capture in the where clause:
    requires: lo >= -2147483648 && lo <= 2147483647,
    requires: hi >= -2147483648 && hi <= 2147483647
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
   the scalar loop; truncation is a ring homomorphism, and order-sensitive
   lane operations agree on range-exact inputs (B4); a chunked reordered
   fold equals the sequential fold for associative and commutative operations
   (B5).
2. **Differential tests**: every vectorized kernel in the test corpus is also
   compiled with vectorization off, and both are run on generated inputs
   (`lib/@vibex/quickcheck`, with fixed seeds). The inputs include lengths
   `0 .. 2W + 1` to cover every tail boundary, and values at the i32 and i63
   extremes.
3. **Negative controls**: a deliberately wrong lowering must fail the
   differential gate. Such lowerings include vectorizing a comparison after an
   overflowing add, `v128.not` for `~` on tagged lanes, a contracted call under
   `bitselect`, a `Double` min/max reduction without NaN canonicalization, `abs(x) > 0` on a loaded `-2147483648`, a shift by 32 on an
   i32 lane, and reassociating a `Double` sum. This is the repository's
   rule that a gate is trusted only once it has been shown to fail (#2248).
4. **A correspondence table** in the eventual ADR. Its last column states,
   operation by operation, whether equality is **proved**, **tested**, or
   **not claimed**.

### B9. What SIMD is not

SIMD is not parallelism. Bend's GPU findings apply to any "run this wide"
annotation. Parallelism must be visible and checked, and balance is the
program's problem. vibe's thread-level story stays ADR-0068: shared-nothing
tasks, with `Parallel::map` over `Send` values. The only link to this proposal
is A4's later slice, which could move a statically unique pointer-free column
into a task instead of deep-copying it. That slice needs a transferable arena
and a one-shot consuming capture rule for spawn closures.

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

**Progress.** Slice 2 has started ahead of slice 1, as §A5 argues it should.
Step 1 is `formal/VibeFormal/Borrow/`. Its core calculus is straight-line and
first-order, with values made of integers, one-cell buffers and pairs, and a
single `borrow` parameter. On that calculus it proves:

- T1 and T1′ in the closed world;
- that four broken checkers (name-only taint, no aggregate taint, no
  projection taint, no escape check) each accept a program that overwrites
  or returns the borrowed buffer.

The next steps extend the calculus one construct at a time, and each
construct brings the review findings that concern it:

| construct | findings it brings |
|---|---|
| calls with write and deep-alias summaries | call-result taint, root-only summaries |
| a second parameter | the T1′ premises, and `consume` sharing a root with `borrow` |
| loops | ω counting |
| closures and effects | the effect-row rule, stored continuations |
| `mut` | exclusivity, buffer-free arguments, reach through globals |

The executable oracle against the selfhost compiler comes after slice 1 gives
the compiler a mode to be compared with.

| # | slice | depends on | new surface |
|---|---|---|---|
| 1 | declared `borrow`, checked against the inferred mask plus a per-parameter write summary; written to `index.vpkg` | — | parameter mode |
| 2 | Lean model + executable oracle for `borrow` / escape (T1), with a negative witness | 1 | none |
| 3 | `mut` exclusivity on shallow buffers (after slice 2's model and witnesses): static place check, buffer-free other arguments, no non-buffer-free globals in the callee's reach, an effect row of at most `Exception` in the callee, entry identity check (T3) | 1, 2 | parameter mode |
| 4 | `consume` with the local usage map (loop and closure bodies count as ω); static uniqueness skips the reuse `rc == 1` test (T2). Spawn-as-move is a later slice, needing a transferable arena and a one-shot consuming capture for direct spawn closures | 1 | parameter mode |
| 5 | i32x4 / i64x2 / f64x2 arithmetic and compare emitters in `codegen/wasm_emit/simd.vibe` | — | none |
| 6 | kernel-subset recognizer + lowering for `Array[Int]` `map` / `count` / `sum` (2×i64, tag-transparent) with the differential gate | 5 | none |
| 7 | `I32Column` (simd-data-structures Layer 3) with the B4 narrowing rule and trap-by-default output | 6 | a type |
| 8 | `#vectorize` + `vibe vectorize-report` | 6 | annotation, query |
| 9 | `F64Column` with `min` / `max` and `sum_unordered` | 7 | a type |
| 10 | shifted-index kernels from a distinct `borrow src` into `mut dst` (never reading `dst`) | 3, 7 | none |
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

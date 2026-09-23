# Bend 2: affinity as the single constraint

Surveyed 2026-09-23. Primary source for the measurements below is
[mizchi/bend-playground](https://github.com/mizchi/bend-playground), which
pins Bend 2.0.23 (commit 75cb8f3e) and reproduces every claim quoted here on
Apple M5 / Metal. Upstream: [bendlang/bend](https://github.com/HigherOrderCo/Bend)
(2.0.26 at the time of writing), notes at <https://bend2.dev/notes/what-is-bend2/>.

## What Bend is

An affine dependent type theory (BendTT) plus a parallel runtime (BendRT) that
compiles to C, Metal and CUDA. Bend 2 is **not** interaction nets / HVM any
more: a node is a 64-bit word, and the runtime is a flat worklist state
machine that the same C file runs on the host and, recompiled, on the GPU.

One restriction does all the work: **a binding is used at most once**.

```
                 affine bindings (use at most once)
                               |
        +----------------------+----------------------+
        |                      |                      |
 a function value      no aliasing              no aliasing
 cannot be duplicated        |                      |
        |              compiler places free   destructive update
 omega / Curry /       (no GC, no tracing)     is safe
 Hurkens do not type         |
        |               the runtime fits on a GPU
 Type : Type is allowed
 (no universe hierarchy, no positivity check)
```

## The checker: a usage map, not context splitting

Each binder carries a quantity. The checker adds up uses and compares at
binder close. This is the part most worth stealing, because it is cheap and
easy to explain in a diagnostic.

| spelling | quantity | meaning |
|---|---|---|
| `-x` | None | erased; usable only in types and proofs |
| `x` | Lone | at most once (the default) |
| `+x` | Many | any number of times, **only when the type is `Data`** |

- sequential uses add: `Lone + Lone = Many`;
- branches join by pointwise **max** (a value used once in each arm is used once);
- at binder close: measured quantity ≤ declared quantity, else
  `x (consumed more than once)`.

Every type has a kind `Kind(q)`: `Type` (at most once) or `Data` (copyable).
**A function type is never `Data`**, and neither is anything that owns a
runtime resource: `Array`, `File`, `Socket`. That kind split is what makes
destructive `Array.set` sound and what stops self-application.

`+x` on `Data` is **not** a deep copy — it compiles to an atomic refcount bump
(`term_keep` → `rfc_bump`). So Bend is not RC-free: it is RC on shareable
data and pure ownership on everything else.

Bend has **no borrows**. Where Rust would lend `&T`, Bend either marks the
parameter `+` (callee may copy) or threads the value back out: reading an
array element returns `(Array<T> & T)` — the array comes back with the element.

## What the playground measured

**Real:**

- single core within C: nbody 5.26 s vs C `-O3` 4.67 s (1.13×); median over
  16 pinned benchmarks 1.21×; a Monte Carlo twin within 1 %.
- the GPU runs ordinary code: the same nbody is 0.127 s on Metal, 36.7× the
  single-core C, with no source change except `!` on the call.
- the allocator is 11× faster than malloc/free on the same structure.
- divergence costs nothing on the GPU (it costs 36 % on CPU through branch
  mispredicts) because Bend uses GPU threads as independent threads, **not as
  vector lanes**.
- Hurkens' paradox fails with `f (consumed more than once)` — a usage error,
  not a universe error.
- the 20,981-line Lean formalization compiles, with no `sorry` and only the
  three standard axioms.

**Overstated or broken:**

- the Lean model is a **smaller, different calculus** than the checker that
  runs (`bend.ts`): no literals, no templates, no `@unsafe`. The
  correspondence is unproved and no CI job compiles the Lean file.
- `@unsafe` on a non-terminating `def` proves any proposition, and the
  checker **exits 0**. It prints a transitive taint list ("N defs rely on
  unsafe or foreign code") — taint tracking without a gate.
- conversion checking can diverge without `@unsafe` (stack overflow on a
  type-level self-reference in dead position).

## The five walls (expressiveness)

From round 2 of the playground (`06-writing-bend.md`), each reproduced as a
probe that the checker rejects:

1. **An array is not `Data`.** It cannot be `+`-shared, cannot be read from two
   forks, and wrapping it in a record does not help. Any algorithm over *one*
   array instance is sequential: frontier BFS, in-place sort, union-find.
   In-place-optimal problems lose to C by an order of magnitude (FWHT: 11×).
2. No forward references (no mutual recursion).
3. `match` only scrutinizes parameters or fields, never a computed value.
4. Self-calls must shrink structurally: `while` needs an explicit fuel `Nat`.
5. A fork's results cannot be opened in place; they must be passed to a `def`.

The escape hatch is the asymmetric one: **a `Data` tree can be shared (`+` is
an RC bump), an array cannot.** "The tree buys fork and loses sharing; the
array has sharing and cannot buy fork."

## Parallelism is not in the type

The sharpest finding for vibe: **neither `!` (send to GPU) nor fork is typed.**
`!` is a parse-time flag the checker never reads; the parallel `let a b = f(x) g(y)`
is an ordinary `Let` to the checker and the compiler decides to fork it.
`p1.bend` (one 16384² maze, sequential) and `p2.bend` (2¹⁸ small mazes under a
fork tree, fully parallel) have identical types. `p1` with `!` type-checks and
took the machine down (a single GPU lane walking 2²⁸ steps inside one Metal
dispatch hit the WindowServer watchdog).

> What the type guarantees: no aliasing, each value used at most once,
> recursion shrinks. What the GPU needs: all of that **plus enough independent
> parallelism** — which appears nowhere in the type.

There is also no work stealing: the fork tree is laid onto fixed 128×128 lanes,
and "balance is the program's job". A sequential fold on the GPU is 100×
slower than one CPU thread.

## Lessons for vibe

1. **Global affinity is too expensive for a general-purpose language.** Every
   wall above follows from making affinity the default for everything. vibe
   already has what Bend buys with affinity for *memory* — Perceus inserts
   drops at last use — so the only thing affinity would add is the static
   uniqueness Perceus currently checks at run time (`rc == 1`). Buy that on an
   opt-in subset, not globally.
2. **The usage map is the right checker for that subset.** Quantities
   {0, 1, ω}, add sequentially, max over branches, compare at binder close.
   Linear-time, no context splitting, and the error names the binder.
3. **The `Data` / `Type` kind split already has a vibe counterpart**: `Send`
   is a compiler-judged structural marker that excludes `Array`, `Bytes`,
   closures and `mut` fields (`checker/checker_trait.vibe`). A "copyable" kind
   and a "sendable" kind are close enough to share one classifier.
4. **An annotation that the checker never reads is a lie waiting for a crash.**
   If vibe adds `#vectorize` or a parallel annotation, it must be *checked*
   (like `#zero_alloc`), and a failure must be a diagnostic, not a slow or
   crashing run.
5. **Taint without a gate is not safety.** Bend's `@unsafe` list is correct and
   useless because the exit code is 0. vibe's `#zero_alloc(assume)` is the same
   shape; any trusted-boundary marker needs a `--deny-*` mode that fails.
6. **A formal model disconnected from the implementation certifies the model.**
   Bend's Lean file is the cautionary tale; vibe's `formal/` directory already
   has the corrective (executable oracles checked against the selfhost
   implementation — see `formal/check-oracle.sh`), and any new model should
   be born with one.

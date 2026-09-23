# Other languages: Bend, Vx, Mojo, and MoonBit verification

Research notes, 2026-09-23. Not normative: nothing here is decided until an
ADR says so. The question behind them is this:

> Can vibe adopt a **formalized borrowing discipline** and **Mojo-style
> vectorization**, if both are designed in from the start and restricted to
> specific patterns (a subset), using MoonBit's verification practice
> ([mizchi/veri](https://github.com/mizchi/veri)) as the model for how to
> prove it?

| note | what it covers |
|---|---|
| [bend.md](bend.md) | Bend 2: affinity as the single constraint, the usage-map checker, the five expressiveness walls, and parallelism that is not in the type. Based on the measurements in [mizchi/bend-playground](https://github.com/mizchi/bend-playground) |
| [mojo.md](mojo.md) | Mojo 1.1: parameter conventions, exclusivity, ASAP destruction, origins, and `SIMD[dtype, width]` + `vectorize` as library code |
| [vx.md](vx.md) | Vx: memory placement in the type, linear types, a scope-depth borrow checker (not to copy), and per-transfer SMT obligations (to copy) |
| [moonbit-veri.md](moonbit-veri.md) | MoonBit `where`-contract verification through Why3/SMT, and veri's practice: model + contract + runtime correspondence + negative controls. Also where aliasing and associativity bite |
| [borrowing-and-vectorization.md](borrowing-and-vectorization.md) | **The proposal**: second-class borrow modes, a lane-wise kernel subset for `v128`, the Lean/oracle plan, and slices in dependency order |

## Conclusions

1. **Borrowing: yes, as second-class parameter modes, not reference types.**
   `borrow` / `mut` / `consume` attach to parameters only, so no lifetime ever
   needs to be inferred or printed. vibe already infers most of it (the
   per-parameter borrow mask, `borrow_ret` / `view_ret`, consume counts). The
   work is to make those facts **declarable and checked**, so that they survive
   a package boundary and a verifier can rely on them. `borrow` reuses the
   existing region escape checks, since a borrow is a region the length of a
   call. `consume` uses Bend's usage map locally, and that gives *static*
   uniqueness, which Perceus today checks only at run time.
2. **The rule that pays twice is exclusivity**: a `mut` buffer argument
   never aliases another argument. It is restricted to shallow buffer types,
   so it is decidable: a static check on places, other arguments of
   buffer-free types only (no struct, closure or type variable that could hide
   the buffer), no globals of such types in the callee's reach, and one
   identity compare at entry. The verifier needs it, because Why3 rejects
   aliased mutable arguments and veri had to split `blit` in two. The vectorizer needs it for
   shifted-index kernels. Perceus does **not** get its `rc == 1` elision from
   it, because the caller may still hold another reference; that elision
   needs `consume`'s static uniqueness.
3. **Vectorization: yes, as a whitelist subset of combinator lambdas, not a
   loop auto-vectorizer.** On wasm the width is a constant 128 bits, so Mojo's
   width parameter disappears. What carries over is `vectorize`'s *shape*: a
   full-width main loop and a width-1 scalar tail running the same lowered
   body. A vector never becomes a vibe value, as already decided in #2342.
   Two rules keep it from ever being silently wrong:
   - narrowing to i32 is honest only for ring operations, so comparisons,
     `min` / `max`, `>>` and `abs` take only range-exact operands (loaded
     values, in-range literals or proven-range captures). Shift counts must
     be literals below the lane width, because wasm masks the count;
   - a reduction needs associativity and commutativity, so there is no
     vectorized `Double` sum unless the API name says `unordered`.
4. **Formalize the way veri does, and not the way Bend does.** Make every model
   executable, diff it against the selfhost as an oracle
   (`formal/check-oracle.sh` already does this for call typing), keep negative
   witnesses (broken checkers and broken lowerings that must fail), and
   publish a table saying which properties are proved, which are tested, and
   which are not claimed. Bend's 21k-line Lean model shows what happens
   otherwise: it certifies a smaller calculus than the checker that actually
   runs. Its `@unsafe` shows that taint tracking with exit code 0 is not a
   gate.
5. **Annotations must be checked.** Bend's `!` and its parallel `let` are
   invisible to the checker, and a program that type-checked crashed the
   machine. A `#vectorize` in vibe should be an assertion that fails with the
   edit that fixes it, the same way `#zero_alloc` works.

## Sources

- Bend: [mizchi/bend-playground](https://github.com/mizchi/bend-playground)
  (Bend 2.0.23 at 75cb8f3e, measured on Apple M5 / Metal),
  [bendlang/bend](https://github.com/HigherOrderCo/Bend),
  <https://bend2.dev/notes/what-is-bend2/>
- Mojo: <https://mojolang.org/docs/manual/values/ownership>,
  <https://mojolang.org/docs/manual/values/lifetimes>,
  <https://mojolang.org/docs/manual/lifecycle/death>,
  <https://mojolang.org/docs/changelog>, and
  [modular/modular](https://github.com/modular/modular) (release notes and the
  standard library's `vectorize`)
- Vx: [vx-lang/Vx](https://github.com/vx-lang/Vx), <https://vxlang.org/>
- MoonBit verification: [mizchi/veri](https://github.com/mizchi/veri),
  <https://docs.moonbitlang.com/en/latest/language/verification.html>
- Wasm SIMD status: <https://webassembly.org/features/>,
  [WebAssembly/proposals](https://github.com/WebAssembly/proposals),
  [WebAssembly/flexible-vectors](https://github.com/WebAssembly/flexible-vectors)
- vibe background:
  [simd-api-design.md](../../internal/design/simd-api-design.md),
  [simd-data-structures.md](../../internal/design/simd-data-structures.md),
  [mutability-control-review.md](../../internal/design/mutability-control-review.md),
  [perceus-reuse.md](../../internal/design/perceus-reuse.md),
  [memory-contract.md](../../internal/design/memory-contract.md),
  [pl-survey-2026-07.md](../../internal/reports/pl-survey-2026-07.md)

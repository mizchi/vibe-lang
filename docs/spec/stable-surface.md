# vibe stable surface

> Status: **accepted** — the record of what vibe promises SemVer stability for,
> and what it deliberately does not. Fine-grained locked decisions live in
> [spec/decisions.md](decisions.md); the full decision log is [adr.md](../adr.md).
>
> **The freeze takes effect at the `0.1.0` tag** — the first release usable by
> anyone but the author (ADR-0109). Until then this document describes the
> surface being frozen, not a promise already made.

This document lists the surface vibe guarantees to external users, and marks the
outside of it — the experimental parts, still open to change.

---

## 1. SemVer policy

vibe follows **SemVer 2.0.0**. The version applies both to the language itself
(the toolchain version `vibe version` reports) and to user packages (the
`version` field in `index.vpkg`).

While the toolchain is on **0.x**, the table below shifts one step down, as
SemVer prescribes for pre-1.0: a breaking change to the stable surface is a
**Minor** bump (0.1 → 0.2) and a compatible change is a **Patch**. The table
applies literally from 1.0.0 on.

| Change | Bump (from 1.0.0) | Example |
| --- | --- | --- |
| Breaking change to the stable surface | **Major** | Changing the meaning of existing syntax, removing a prelude symbol, removing a CLI command |
| Compatible addition to the stable surface | **Minor** | New syntax sugar, new prelude symbol, new CLI flag |
| Change with no observable behavior difference | **Patch** | Bug fix, better diagnostic message, internal optimization |

Trait bound compatibility follows the lock in [decisions.md](decisions.md):
**tighter bounds = Major / looser bounds = Minor**.

The **unstable surface (§6)** is outside this guarantee. Those parts can break
within a Minor.

**How the unstable surface is marked.** By a mechanism the compiler enforces,
never by an ADR's status — status is bookkeeping a reader never sees, and a
surface marked only that way compiles clean with no marker of any kind.

What is enforced today, measured 2026-08-24:

| surface | how it is gated |
| --- | --- |
| wasm-gc backend | opt-in env var (`VIBE_BACKEND=gc` and friends) |
| `perform?` | the checker rejects it, naming the edit that fixes it |
| SIMD | the package does not resolve |
| **ADR-0068 concurrency** | **`import @vibe/concurrent` is rejected by `vibe check` AND by `vibe build`; `VIBE_UNSTABLE=1` allows it** |

An **error**, not a warning. `vibe check` exits non-zero and `vibe build`
emits no wasm; the diagnostic names the environment variable that opts in.
Both verbs answer the same way on purpose — a build that accepts what the
check rejects is the "two verbs, two answers" defect #1567 fixed for
check/diagnostics, and it is worse here because the accepting verb is the one
that ships.

The gate reads the entry file's **parsed** imports, so whitespace does not
cross it (`import\t@vibe/concurrent` is the same as `import @vibe/concurrent`),
and it looks at the entry only: a dependency's own imports are its author's
choice. Harnesses inside this repository that compile in-tree sources against
the surface deliberately (the book's concurrency chapter, the unit-test
batch) grant the opt-in themselves; the boundary is pinned by
`tests/gates/late/run.sh` section 108.

The rest of §6 is still a reading obligation rather than an enforced boundary.

---

## 2. Frozen language core (syntax & semantics)

Everything below is demonstrated by the selfhost usability sign-off
(`docs/archive/report/0-1-0-usability-signoff.md` — an internal quality
milestone from 2026-06, not a release; see ADR-0109). The canonical definition
of each item is [spec/syntax.md](syntax.md) and the
[cheatsheet](../cheatsheet.md).

### 2.1 Values and types
- Primitives: `Int` (63-bit tagged, literals up to 2^62-1, arithmetic wraps as
  63-bit two's complement — ADR-0006, #1877), `Float` (32-bit), `Double`
  (64-bit), `String` (a **byte** string with byte-offset indexing, ADR-0098),
  `Char` (an `Int` alias), `Bool`, `Unit`.
- Literals: integers (decimal / `0x` hex), floats (`1.5f` / `3.14`), strings
  (interpolation `\{expr}`), chars `'A'`, `true`/`false`, `()`.
- Composite types: tuples `(A, B)`, `Array[T]`, `StringMap[V]` (the builtin
  map; `Map[K, V]`'s generality is not frozen — see §3), record, struct,
  enum, function types `(A) -> B`, effectful `(A) -> B with E`, generics `[T]`,
  trait bounds `[T: A + B]`, and the `Option[T]` sugar `T?` (ADR-0046).
- **Equality (`==`) — the fail-closed contract** (ADR-0097 as shipped; measured
  2026-08-19, #1526/#2157/#2192): where the operand's element type is known —
  bare, through a name, inside tuples/structs/nested arrays, through a function
  result, and for an unannotated `let xs = []` whose pushed values describe
  themselves — `==` is **structural**. A comparison the compiler cannot
  classify **traps at the comparison** once both sides are non-empty rather
  than answering by length or identity; adding a type annotation resolves it.
  An erased type variable (`[T: Eq]`) dispatches through its witness and is
  rejected at check time for a container with no `Eq` impl; an UNBOUNDED
  formal comparing containers (`fn f[T](x: Array[T], y: Array[T])`) is the
  trap side of the same contract — measured 2026-08-24, an
  equal-but-separately-allocated pair traps rather than answering, and a
  difference answers `false`. There is **no silent reference equality**
  anywhere on this surface — every lane answers correctly or traps. SemVer
  reading: a
  currently-trapping comparison later becoming a structural answer is a
  compatible change (the typed lane, #2158); an existing answer changing is
  breaking. The full contract is the cheatsheet's "`==` on `Array` / `Bytes`
  (#1526)" section, pinned by `fixtures/structural_eq_contexts_test.vibe` and
  the `structural_eq_untyped_empty_*_trap` fixtures.

### 2.2 Bindings and mutability
- `let` (immutable), `let rec` (recursive), `let mut` (block-scoped mutable,
  ADR-0017).
- Destructuring `let (a, b) = ...` / `let Some(v) = e else { ... }`.
- The five mutation styles (see the cheatsheet's table), `struct { mut field }`
  (ADR-0052 — despite that ADR's wasm-gc framing, these run on the linear lane
  too; measured 2026-08-19).

### 2.3 Functions and calling convention
- Lambdas `(x) -> { ... }`, and the separated-annotation form
  `let f: (T) -> U = (x) -> { ... }`.
- Labeled arguments `f(x=10)` / `x~`.
- Shorthands: sections `_ * 2`, the `_` placeholder.
- **Pipe-first** `x |> f` (ADR-0020) with `_` slot substitution.
- `.` is field access only — there is no method-call sugar.
- Name resolution order: local > lexical > import > prelude.

### 2.4 Control flow
- `if`/`else` (an expression), `match` (with `if` guards and or-patterns
  `A | B`), `while`, `for-in` (collects into an `Array`; indexed form
  `for i, x in`), `loop`/`break(v)`/`continue(...)` (ADR-0047), `return` for
  early exit.
- Patterns: wildcard, binding, literal, constructor, tuple, record, struct,
  or-pattern, guard.
- The `is` expression `expr is Pat` (ADR-0023).

### 2.5 Type definitions and traits
- `type` aliases, `enum`, `struct`, `derive(Eq)` (ADR-0045).
- Traits: nominal and marker (v0, decisions.md), supertraits `trait Ord: Eq`,
  `export trait` (sealed) / `export open trait` (extensible), conditional impls
  `impl [T: Eq] Eq for Array[T]`.

### 2.6 Effect system
- Pure by default, with `with E` annotations.
- `throw` / `handle ... with Exception { ... }`, the `?` operator (ADR-0016,
  ADR-0050). `throw(x)` is call-form and sugar for
  `perform Exception::Throw(x)` (#640); the bracketless `Exception` row is
  erased — its payload is deliberately unconstrained.
- `suberror` (typed errors) and **typed exception rows `Exception[E]`**
  (ADR-0085, #1344): the row names the thrown payload's **static type**
  (`with Exception[IoError]` — `E` is any payload type: an enum, a
  `suberror`, or a primitive such as `String`), kinds compose by `effectset`
  union, and a kind missing from the row is a check-time diagnostic. The
  exact-kind discharge is a **checker-side** guarantee over statically kinded
  rows: `Exception[IoError]::Throw` discharges exactly `IoError` where the
  handled expression's row is kinded. Where that row is **erased**, kinded
  and erased are compatible in both directions and the runtime carries a
  single abortive tag, so a kinded handler also discharges an erased throw
  whose payload may be another kind. The gradual reading is likewise part of
  the contract: a payload whose kind cannot be resolved (a pattern binder, a
  field projection — an ordinary local binding IS resolved from its
  initializer) is treated as erased and passes any `Exception[K]` — no false
  positives, known misses. Tightening any of this rejects programs and is a
  breaking change.
- User-defined algebraic effects: `effect` / `perform` / `handle ... with` /
  `resume` (one-shot, lexically scoped — ADR-0050, ADR-0021 Phase 1
  tail-resumptive).
- Effect polymorphism `with e`.

### 2.7 Module system
- `export` / `import ./path { names }` / `as` renaming / `type` and `trait`
  imports / re-export.
- `module Name { ... }` blocks, qualified `Type::method` / `Module::name`.
- Package references `@json` / `@lib/path`.
- An import path may not escape the file's root (locked).

---

## 3. Frozen standard library / prelude surface

The stable symbols listed under "Key Builtins" in the
[cheatsheet](../cheatsheet.md) are frozen:

- **String** (compiler builtin, no import needed): `length`, `concat`,
  `substring`, `contains`, `index_of`, `split`, `trim`, `starts_with`,
  `ends_with`, `join`, `from_char_code`, `char_code_at`, `byte_at`,
  `from_byte`.
  `replace` / `replace_all` are **not frozen** as builtins: they are library
  functions in `@vibe/builtin`, reached by
  `import @vibe/builtin { String::replace }`, and are not in the builtin
  registry.
- **Array**: `length`, `get`, `slice`, `concat`, plus `ArrayBuilder::new/push/freeze`.
  `map`, `filter`, `fold`, `find`, `any`, `all`, `reverse` cannot be frozen as
  first-class values (call-only operations: `Array::map(xs, f)`, not
  `let g = Array::map`; #2275).
- **StringMap** — the String-keyed builtin map. Its type is spelled
  `StringMap[V]`; the operations keep the `Map::` qualifier, so the spelling
  is the type's, not a second operation family. Neither needs an import.
  `Map::get`, `Map::has_key`, `Map::keys`, `Map::values`, `Map::set`, `Map::size`, `Map::new`, and `Map::from_pairs` cannot be frozen as first-class values -- they are call-only builtin operations (`Map::get(m, k)`, not `let g = Map::get`; #2274 / #2275).
  **`Map[K, V]`'s generality is deliberately NOT frozen** (#2263): the builtin
  is String-keyed today, and an annotation naming a concrete non-String key is
  rejected where it is written. The name `Map` is reserved for the generic
  type; completing it turns a rejection into an answer, which is a compatible
  change. A key that is a type parameter is unaffected — generic code over
  `Map[K, V]` keeps compiling.
  **Another key type is already available today**: `MutMap[K, V]` from
  `@vibe/core` is the generic open-addressing map, and it is what the
  rejection points at (`MutMap::new_int()` / `new_string()`, or
  `MutMap::new(hash_fn, eq_fn)` for any other key). It is a library type, so
  it is frozen by §3's `@vibe/core` entry rather than by the builtin surface.
- **Int64Array**: `make`, `get`, `set`, `length` cannot be frozen as
  first-class values (call-only; #2275).
- **Conversions**: `Int::to_double`, `Double::to_int`.
  `Int::to_string` cannot be frozen as a first-class value (call-only; #2275).
- **Iteration**: the `Iterable` trait and the `for-in` desugar (ADR-0044). The
  **combinator layer (`Iterator::map` and friends) is not frozen** — it is
  retired by ADR-0099's two-layer split and has zero rows in the registry
  (measured: `Iterator::` 0 hits). Eager iteration is the call forms
  `Array::map` / `Array::filter` / `Array::fold` (cannot be frozen as
  first-class values; see Array above).
- **@vibe/builtin helpers**: `compose` / `identity` / `flip` (func), and the
  `let*` railway bind. `Result::and_then` **cannot be frozen** — `Result` was
  removed from the language in #1324, and `Result::` has zero registry rows.
  `tap` / `tap_some` moved to `@vibe/console` in #2102 (`tap_ok` / `tap_err`
  were removed in #1324).
- **I/O** (an effect is required): `println` / `print` (`{Stdout}`, builtin) and
  `@vibe/console`'s `read_line` (`{Stdin}`). `sh` / `sh_lines` (structured
  shell) carry **`{Process}`**, not `{Stdout}`.

> **Adding** a prelude symbol is a Minor. **Removing** one, or changing its
> signature, is a Major.

This list is checked against the compiler by
`scripts/check_freeze_surface.sh` (`pkf run check-freeze-surface`), which
derives the symbols from this section and probes each one.

---

## 4. Frozen CLI / tooling surface

The following subcommands and contracts of the `runtime/vibe` launcher are
frozen:

| Command | Contract |
| --- | --- |
| `vibe run <file>` | Compile and execute. `--trace` / `--break` are opt-in debugging. |
| `vibe compile` / `vibe build [--release] <file>` | Produce a standalone `.wasm`. |
| `vibe check [--single-file] [--json] <file>` | Type-check only. Located diagnostics (`line N:M:`) on **stdout**, one per line. **Clean = empty output + exit 0**; any diagnostic means exit 1. `--single-file` analyses one file without resolving imports (for unsaved editor buffers); `--json` exists in that mode only (#1567). |
| `vibe test <file\|dir>` | Run test blocks. |
| `vibe new` / `vibe add` | Initialize a project / add a dependency. |
| `vibe fetch [--frozen]` / `vibe verify` | Fetch modules / verify the lock. |
| `vibe lsp` | LSP server. |
| `vibe type-at` / `vibe binding-at` | Editor integration primitives. Always exit 0 — they are queries, not verdicts. |
| `vibe diagnostics` | **Deprecated** (#1567): `vibe check --single-file` is the successor. Kept with frozen behavior for existing editors — raw diagnostic lines (no `error: ` prefix), always exit 0. |
| `vibe version` | Report the toolchain version. |
| `vibe self update --cli-wasm <path>` | Replace the compiler wasm, independently of the runner. |

- **Distribution model**: a purpose-built wasmtime runner and the compiler wasm
  ship separately, `.cwasm` AOT compilation happens at install time, and the
  compiler updates independently of the runner.
- **Module distribution**: distributed over git/URL with no central registry,
  locked by content hash (`index.lock`), resolved against semver constraints
  (`^` / `~` / `>=` / `x` / `*`).
- File conventions: `*.vibe`, `index.vpkg` (the package contract, and the
  public API boundary — ADR-0070), `index.lock`, `*_test.vibe`. `index.vibe` is
  a facade, not a boundary, and `index.vibei` is legacy and no longer exists in
  the repository.

---

## 5. Frozen formatting / canonicalization

As locked in [decisions.md](decisions.md):
- The enum variant separator canonicalizes to `;`.
- Struct literals use the `Type::{ ... }` style.
- The formatter (`vibe fmt`) is idempotent.
- Type naming: user types are CamelCase; the wasm builtin primitives (`i32`,
  `f32`, `f64`) are reserved in lowercase.

---

## 6. Not frozen (unstable surface)

The following is still under construction or its design is not settled. It is
**outside** the SemVer guarantee and can break within a Minor. Use it knowing
that.

- **Structured concurrency / WASI 0.3** (ADR-0068, `proposed`): `Nursery[r]`,
  `Task[r,T]`, `Sender`/`Receiver`, `TaskGroup::run` / `spawn` /
  `spawn_suspend`, and the `Send` eligibility rule. Today's codegen is an eager
  prototype; the public semantics are defined in the
  [structured concurrency spec](../concurrency.md). JSPI/Worker, the WASI
  Component Model, and shared-everything threads are interchangeable lowerings
  — the stable surface is tied to none of them.

  **The `Async` effect ROW ELEMENT is not in this bullet.** ADR-0012 is
  `accepted`, and `Async` already appears in shipped builtin signatures a user
  can reach (`StdinStream::next(StdinStream) -> Int with Async`), where `vibe
  check` enforces it like any other row element. The unsettled part is the
  concurrency model built on top of it, not the vocabulary.
- **Component Model `#import` integration** (ADR-0021 Phase 2/3): CPS lowering
  of non-tail-resumptive handlers, capability effects.
- **Capability authorization surface** (ADR-0088, `proposed`): the two-clause
  `with {A} allows {C}` syntax (parser landed), the `?` grade for optional
  capabilities, the `Attempt[T, E]` that `perform?` returns (the type and
  `unwrap_or` / `is_granted` are in `@vibe/core`), and preflight authorization.
  ADR-0043's `--allow-*` / `--deny-*` / `--profile` presets were not built as a
  separate feature; they were absorbed into L1 of this resolution ladder.
- **`_start` capability declarations and the top-level effect rule**
  (ADR-0041/0042, `proposed`).
- **The SIMD API** (`spec/simd-api-design.md`).
- **Line-granularity debugger stepping and call-site hover** (span-arc):
  function-granularity stepping and typed hover are stable; line-granularity
  stepping and arbitrary-expression watch are a future extension.
- **Incremental analysis in the LSP** (optional).
- **The wasm-gc backend compiles one file at a time** (`VIBE_TEST_BACKEND=gc`):
  *using* an imported name fails with a diagnostic naming the import and
  pointing at the linear backend (an unused import is fine, #1976). The linear
  backend is the stable surface; gc is opt-in and experimental. Builtin-level
  differences are enumerated in
  `scripts/builtin_parity_classification.tsv` and enforced at the gate.

---

## 7. Operating the freeze

- After the `0.1.0` tag, a proposed change to the stable surface (§2–§5) must
  state its SemVer impact in an ADR.
- When something on the unstable surface (§6) settles, move it into §2–§5 here
  and update the corresponding ADR to `accepted` — it enters the stable surface
  in the next Minor.
- The toolchain version `vibe version` reports is the SemVer reference point.
  The version ladder itself is ADR-0109.
- Revisions to this document are tracked in the ADR log's "Release / GA"
  section.

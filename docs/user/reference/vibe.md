# vibe language specification

This document captures the current vibe design: a Rust/MoonBit-like, statically
typed, pure functional language with explicit effects, built for WASM/wasip3.

## Status and authority

- `docs/user/reference/syntax.md` is the canonical surface syntax reference.
- `docs/user/reference/vibe.md` is the broader language design/spec note for implemented
  behavior outside pure syntax (effects, imports, hashing, runtime contracts).
- Items explicitly marked as "future", "proposal", or "draft" are non-normative.
- Package boundaries, visibility, and pinning are specified separately:
  - `docs/internal/design/module-system-oracle.md` (canonical)
- Incident log for compiler/language regressions:
  - `docs/archive/compiler_language_incidents.md`

## Goals

- A statically typed functional language with explicit effects; the design
  pillars are stated in `AGENTS.md`.
- Pure by default; semantic effects including `Exception` are explicit
  (`with ...`) and can be locally discharged with effect handlers.
- Content-addressed functions (Git blob compatible) with Unison-style aliases.
- Incremental pipeline: CST -> AST -> monomorphized AST -> canonical S-expression -> hash.

## Syntax dispatch

There is one syntax. The MoonBit host's `--syntax` selector and its PosixMode
command-head desugar (`ls` -> `sh_lines("ls")`) went with the host (#594); no
command accepts `--syntax`, and `sh_lines` is not a builtin.

`fn` is the preferred top-level named-function declaration: it requires typed
parameters and a return annotation, supports generics/effect rows, and lowers to
the equivalent recursive `let` form before checking and code generation. See
[Functions and Lambdas](syntax.md#functions-and-lambdas).
- `map` is not a reserved keyword and can be used as a normal identifier.

## Standard tutorial scope (v1 core)

Included in standard tutorial:
- core expressions/statements: `let`, `if`, `match`, `while`
- module API: `import` / `export`
- data model: `enum` / `struct` / tuples / arrays / records
- error flow: the `Exception` effect row (`throw` / `handle`, `?`)
- effects: explicit `with ...`
- effect handling: `handle` arms for effect/local error pattern matching

Documented but excluded from standard tutorial:
- placeholder lambda shorthand (`_` in call arguments)
- raw identifiers (`r#name`)
- boundary-style exceptions (`throw`)
- local mutation (`let mut`), `Ref[T]` abandoned (→ ADR-0021)

## Effects

Semantic effects are explicit in function signatures and validated by effect
compatibility plus handler matching. `Exception` is checked and propagates like
other operation requirements under ADR-0073.

ADR-0073 and the Lean model are the specification Oracle. Since #944 the
checker enforces the exception row by default: a direct `throw`/`perform
Exception::Throw`, a call to a `with Exception` function, and an
Exception-rowed callback parameter all require the caller to declare or
`handle` it.
An entry declared `with Exception` gets a runtime boundary handler: an
escaping Throw becomes `vibe: uncaught error: <msg>` on stderr and an
unsuccessful process outcome. Remaining #944 tail: the builtin-call exception
carve-out (sub-decision) and the temporary `VIBE_CHECK_ERROR_ROW=0` opt-out.

```
let run: () -> Unit with Process = () -> {
  sh("ls")
}
```

Rules:
- Effect signature requirement:
  a function's declared effects must be a superset of the effects used inside.
  (`with ...` is the capability contract.)
- Checked exception requirement:
  `throw(x)`, `perform Exception::Throw(x)`, and calls to a function annotated
  with `with Exception` require the caller to declare or handle `Exception`.
- Handler requirement:
  effects can be localized by `handle` arms that pattern-match the handled
  operation/error payload.
- `with ()` is optional; omission means no semantic effect requirement,
  including no escaping `Exception`. It does not guarantee termination or exclude
  panic, Wasm trap, or resource exhaustion.
- `do` is not part of the current surface syntax.
- Current builtin mapping (the row tag each entry carries in
  `lib/@vibe/compiler/core/builtin_registry.vibe`):
  - `sh(...)` requires `{Process}`
  - `Console::write_char(...)` requires `{Console}`
  - `Console::write_stream(...)` requires `{Console}`
  - `Stdout::write_char(...)` requires `{Stdout}`
  - `Stdout::write_stream(...)` requires `{Stdout}`
  - `Stdin::read_char()` requires `{Stdin}`
  - `Stdin::read_stream(...)` requires `{Stdin}`
  - `sleep(...)` requires `{Async}`
- The concurrency surface is `lib/@vibe/concurrent` (`TaskGroup`, ADR-0068);
  importing it is authorized per compilation by `VIBE_UNSTABLE=1`. There is no
  `--unstable-async` flag.

Examples:

<!-- doctest-skip: 意図的な type error 例 (ok/error 対比の提示) を含むため単体コンパイル不可 -->
```vibe skip
// ok: declared effect allows direct builtin call
let run: () -> Unit with Process = () -> { sh("ls") }

// error: missing effect declaration for direct effectful builtin call
let run: () -> Unit = () -> { sh("ls") }

// error: the exception row propagates transitively
let fail: (String) -> Int with Exception = (msg) -> { throw(msg) }
let g: (String) -> Int = (msg) -> { fail(msg) }

// ok: caller propagates the exception row explicitly
let g2: (String) -> Int with Exception = (msg) -> { fail(msg) }

// ok: effect is localized by handler pattern
let g3: (String) -> Int = (msg) -> {
  handle { fail(msg) } with Exception { Throw(_) => 0 }
}
```

### Error model (effect-row-first, current policy)

- `Exception` is checked: direct throws and transitive calls require declaration
  or handling. An empty effect row excludes an escaping exception, but not divergence
  or runtime traps.
- `fn main allows Exception` is allowed; the runtime boundary converts an
  escaping exception into a diagnosed unsuccessful process outcome.
- The standard error model is the **effect row**: a fallible function returns
  its success type and declares the failure in its row —
  `fn f(..) -> T with Exception[E]`. There is no built-in `Result[T, E]`
  (#1324 removed it from the language and the prelude); a two-track return type
  is now an ordinary user `enum` you declare yourself.
- Pipelines compose by ordinary application: the success value flows straight
  through, so stages chain without `and_then`/`map_err` and without a per-call
  `match`. Failure short-circuits to the nearest `handle`.
- `throw` raises the failure; `handle .. with Exception[E] { Throw(e) => .. }`
  is where it is discharged. Keep `handle` at the boundary you actually want to
  recover at (adapters, CLI/HTTP/FFI, tests) rather than at every call.
- `handle` remains the core mechanism for local effect/error pattern handling.
- `perform` / `resume` are effect-handler operations used with `handle` and are
  checked together with effect declarations.
- `String` is a built-in `Error`, and `suberror` can define project-specific
  error types.

`suberror` declarations:
- `suberror MyError(String)` is shorthand for an enum-like error type with a
  single constructor `MyError(String)`.
- `suberror AppError { Io(String); Parse(Int); }` uses enum-style constructors.
- `suberror` auto-registers `impl Error for <Type>`.

```vibe
suberror AppError {
  Io(String);
  Parse(Int);
}

// #1324: a suberror is thrown, not returned in a `Result`.
fn fail() -> Unit with Exception[AppError] {
  throw(Io("io"))
}
```

Pipe-first error-flow guideline:
- the pipeline core should carry failure in the effect row
  (`-> T with Exception[E]`), so stages chain on the success value.
- terminal boundaries (`handle`, project-local `unwrap`) should be isolated at
  adapter edges (CLI/HTTP/FFI/tests).
- avoid scattering multiple implicit boundaries across one flow; make the
  boundary location explicit in code.

```vibe
// stubs so the guideline block is self-contained
fn parse_id(raw: String) -> Int with Exception[String] { 1 }
fn validate_id(id: Int) -> Int with Exception[String] { id }
fn load_user_id(id: Int) -> Int with Exception[String] { id }

fn run_core(raw: String) -> Int with Exception[String] {
  raw |> parse_id |> validate_id |> load_user_id
}

fn run_cli(raw: String) -> Int {
  handle { run_core(raw) } with Exception[String] {
    Throw(_) => 0 - 1
  }
}
```

### Generics with effects (current)

Effect polymorphism and type polymorphism are checked together.

Rules:
- Effect row variables (for example `with e`) can appear with generic type
  parameters in higher-order function signatures.
- At call sites, type variables and effect variables are instantiated together.
- If a callee's effect requirement escapes through a wrapper, the wrapper must
  declare a compatible effect set.
- Trait bounds and effect checks are independent constraints; either can fail
  first depending on the call shape.

> **Enforced (#885, fixed; previously a known gap tracked at #838):** the third
> rule above ("the wrapper must declare a compatible effect set") is now
> checked for the callback-PARAMETER case — a wrapper whose body directly
> invokes an effect-row-polymorphic callback parameter (e.g. `f: (T) -> T with
> { e }`) must itself declare a compatible `with ...` row, or the checker
> rejects it. `check_perform_effects_expr_tx` (`checker_effects.vibe`) now
> tracks function-typed PARAMETERS as call-graph leaves, alongside named
> top-level bindings, and no longer exempts a row-variable label reached
> through one. The `apply` example below (missing `with e`) is a checker
> error today, as its comment says. (Scope note: this covers the callback's
> OWN declaring function; unifying a row variable against the concrete effect
> a specific *call site's* argument instantiates it with — e.g. detecting that
> `apply(risky, 1)` needs `{Exception}` when `apply` itself correctly declares
> `with e` — still needs real call-site effect-row unification and remains
> open.)

> **Enforced (#1361):** the same rule holds for a LOCAL closure. A
> `let f = () -> T with E { ... }` written inside a function body is a
> call-graph leaf just like a top-level function or a callback parameter, so
> calling `f()` requires the enclosing function to declare `E` (or to be under
> a `handle` that discharges it). Until #1361 neither table saw such a
> binding — the call-graph map is built from top-level bindings and the
> overlay from function-typed parameters — so the closure satisfied its own
> declared row and the requirement never surfaced at the call site:
>
> ```vibe skip
> // error (ENFORCED — #1361): main declares only { Console } but reaches Env
> let main = () -> Unit with Console {
>   let read_home = () -> String with Env { Env::get("HOME") }
>   println(read_home())
> }
> ```
>
> This also closed the doctest / `vibe test` cache half of the same hole:
> `file_entry_cacheable` / `file_tests_cacheable` reuse this walk, so an entry
> whose output tracked the environment through a local closure used to be
> judged deterministic and replayed from cache. (Scope note: an ANNOTATED local
> binding, `let f: () -> T with E = ...`, is desugared to an ascription call
> before this walk runs, so its row is not visible here and that spelling keeps
> the older, permissive behavior.)

Examples:

<!-- doctest-skip: intentional type error example (ok/error contrast
     presentation) — the `apply` case below is REJECTED by the checker
     (#885) and cannot share a single compiled unit with the `apply_ok` case
     below it, so it stays a prose-only illustration; see `apply_ok` for a
     live-verified compiling counterpart. -->
```vibe skip
// error (ENFORCED — #885): wrapper body calls an effect-polymorphic
// callback without declaring {e}
let apply: [T](f: (T) -> T with e, x: T) -> T = (f, x) -> {
  f(x)
}
```

```vibe
// ok: wrapper propagates effect requirement explicitly
let apply_ok: [T](f: (T) -> T with e, x: T) -> T with e = (f, x) -> {
  f(x)
}
```

## Local mutation (`let mut`)

Design policy (ADR-0017):
- `let mut` is local deterministic state, not an externally observable side
  effect.
- local mutation is hash-safe when it is confined to lexical scope and cannot
  escape async boundaries.
- `let mut` is the primary user-facing model for local mutable state.

Constraints:
- `let mut` variables are block-scoped and cannot remain live across
  `await`/`spawn`.
- `let mut` variables cannot be captured by async closures.
- Snapshotting is required to pass data into async closures.

> **Note**: there is no `Ref[T]`. Cross-call mutable state is a user-declared
> algebraic effect with a handler (ADR-0021). The row label `Mut` is reserved
> for a future marker of argument mutation (ADR-0100 (2), #3045): a row naming
> it and a user `effect Mut` are refused today.

Lightweight effect tiers (policy direction):
- `pure`: no external effects, no local mutable state.
- `state_local`: local mutable state only (`let mut`).
- `impure`: external effects (I/O, shell, time, randomness, etc.).

Current effect signature checks continue to gate `impure` operations.
Top-level purity diagnostics preserve `state_local` tier through local call
chains (`let mut`-using helper functions).

Discard binding (`let _ = ...`):
- `_` is a wildcard discard binding and is not stored in value/type namespaces.
- `let _ = ...` can be used multiple times in the same scope.
- `let rec _ = ...` is rejected.

Raw identifier (advanced):
- `r#<ident>` escapes reserved keywords and forces identifier interpretation.
- Example: `let r#if = 1`, `let r#bench = 2`.
- Internally the bound name is normalized to `<ident>` (`if`, `bench` in the
  examples).

## Labeled arguments (MoonBit-style)

Definition:
```
let foo: (x~: Int, y?: Int) -> Int = (x~, y?) -> {
  match y? {
    Some(y) => x + y,
    None => x,
  }
}
```

Call:
```
foo(x=1)
foo(x=1, y=2)
```

Shell view (conceptual):
```
foo -x=1 -y=2
```

Rules:
- `x~` is required (must be supplied by label).
- `y?` is optional and is bound as `Option[Int]` inside the function body.
- Default values in parameter lists are not part of the current surface syntax.
- Call arguments are reordered to match the parameter order during lowering.
- Missing optional args are passed as `None`.

## Builtins (current)

Array/Map:
- `Array::length(array)` -> `Int`
- `Array::get(array, index)` -> element
- `Map::get(map, key)` -> element (key is `String`)

String:
- `String::length(string)` -> `Int`
- `String::char_code_at(string, index)` -> `Int`
- `String::from_char_code(code)` -> `String`
- `String::substring(string, start, end)` -> `String`
- `String::concat(left, right)` -> `String`
- `String::equals(left, right)` -> `Bool`

StdIO (wasi stream primitives for wasm/component-friendly interop):
- `Console::write_char(code)` -> `Unit` with `{Console}`
- `Console::write_stream(text)` -> `Unit` with `{Console}` (chunk write)
- `Stdout::write_char(code)` -> `Unit` with `{Stdout}`
- `Stdout::write_stream(text)` -> `Unit` with `{Stdout}` (chunk write)
- `Stdin::read_char()` -> `Int` with `{Stdin}` (`-1` = EOF)
- `Stdin::read_stream(max-bytes)` -> `String` with `{Stdin}` (`""` = EOF/error)
- component WIT/wasm import mapping:
  - `Console::write_char` -> `wasi:cli/stdout@0.2.0#get-stdout` + `wasi:io/streams@0.2.0#[method]output-stream.blocking-write-and-flush`
  - `Console::write_stream` -> same as `Console::write_char` (single host call for whole chunk)
  - `Stdout::write_char` -> same stdout import as `Console::write_char`
  - `Stdout::write_stream` -> same stdout import as `Console::write_stream`
  - `Stdin::read_char` -> `wasi:cli/stdin@0.2.0#get-stdin` + `wasi:io/streams@0.2.0#[method]input-stream.blocking-read`
  - `Stdin::read_stream` -> same as `Stdin::read_char` (cabi read-buffer -> vibe string)

Concurrency (v0.4.0 proposed):
- 過去の `Threads::*`（raw Int channel id、String message、probe/runtime hint）は
  撤去済みの実験 API であり、現在の builtin surface ではない。
- 現行 `Task[T]` は synchronous eager prototype で、並行実行の契約ではない。
- 公開モデルは generative nursery、region-bound `Task` / typed channel、`Send`、
  task-local handler evidence とする。詳細は
  [ADR-0068 detailed concurrency spec](../../internal/design/concurrency.md)。
- JSPI / Worker、WASI Component Model、shared-everything-threads は公開 API ではなく
  同じ意味論の backend lowering とする。

Builtin contracts: see `docs/user/reference/cheatsheet.md`'s Signature reference, checked against
the checker's own builtin table by `scripts/check_cheatsheet_signatures.sh`. Do not
infer proposed concurrency APIs from any builtin table; ADR-0068 is authoritative.

## WASM Primitive Type Aliases

Type positions accept wasm-style primitive aliases:
- `i32` == `Int`
- `f32` == `Float`
- `f64` == `Double`

Rules:
- These aliases are parser-level synonyms and normalize to canonical vibe types.
- `i32`/`f32`/`f64` are reserved type names and cannot be redefined with `type`, `enum`, or `struct`.
- Canonical type names (`Int`/`Float`/`Double`) remain the public spec baseline.

WASM intrinsic names:
- wasm `i32.add` style operations can be referenced as `vibe/wasm/i32::add`.
- Legacy underscore names (for example `i32_add`) are normalized to the canonical intrinsic name.

## Names, hashes, versions, and symbols (Unison-style)

vibe uses a layered reference model:

- `HashRef`: immutable content address of canonical S-expression IR (source of truth).
- `VersionRef`: mutable namespace/branch pointer to hashes.
- `SymbolRef`: mutable human-readable name pointer to hashes.

Execution and dependency identity are hash-based. `VersionRef`/`SymbolRef` are
authoring/navigation aliases that normalize to hash before evaluation.

### Canonical reference schema

Reference forms accepted by parser and importer:

- `PathRef`: `./foo.vibe`, `../foo.vibe`, `/abs/foo.vibe`, `"./foo.vibe"`
- `HashRef`: `#<hash>`
- `VersionRef`: `version@<name>` (canonical), `version:<name>` (compat)
- `SymbolRef`: `symbol@<name>` (canonical), `symbol:<name>` (compat)

Normalization rules:

1. `PathRef` resolves to content and is mapped to a hash.
2. `VersionRef` resolves through `version -> hash` lock metadata.
3. `SymbolRef` resolves through `symbol -> hash` lock metadata.
4. All resolved imports are rewritten to `HashRef` in compiled AST.
5. Runtime evaluation only accepts hash-resolved imports.

Current in-memory lock key conventions:

- hash snapshot: `__hash__/<hash>`
- version binding: `__ref__/version/<name>`
- symbol binding: `__ref__/symbol/<name>`

Current shorthand:
- `name#abc` = symbol with hash prefix (shortest unique allowed).
- Hash prefix resolution: unique match resolves; 0 or >1 matches is an error.

### Immutability rule for pure definitions

- Once a pure function is stored under a hash, it is never mutated in place.
- Source edits produce a new hash.
- "Updating" a function means rebinding symbol/version refs to the new hash.

### Edit/readability rule

`edit` should reconstruct readable code from namespace/lock metadata:

1. Prefer symbol names when mapping is unambiguous.
2. Use `name#hashprefix` when disambiguation is needed.
3. Fall back to raw hash refs when no symbol mapping exists.

Standalone `alias ... = ...` and `flake { ... }` statements are removed.

## Content address and hash layers

Current module identity uses Git blob compatible `sha1` over canonical
S-expression bytes:

```
ir = module_to_sexp(resolved_ast, aliases)
hash = sha1("blob " + len(ir_bytes) + "\0" + ir_bytes)
module_ref = "ko-doha/vibe/" + hash
```

- Content hash input is canonical S-expression IR produced by compiler pipeline.
- Human-facing metadata (path aliases, formatting trivia, spans) is excluded.
- There is no `sha256` content hash path in the current compiler.

Separate internal hash:
- `Module::structural_hash() -> Int` is used only for incremental query equality
  (`HashedModule`) and backdate optimization; it is not a persistent content ID.

## Imports and exports

### Surface syntax (current)

Imports are source-first `import` only:

<!-- doctest-skip: 存在しない import 先 / hash・version・symbol ref の構文一覧 (#831: 欠落 import 先は raw crash になる) -->
```vibe skip
import ./path/to/mod.vibe { foo, bar as b }
import ./path/to/mod.vibe { type IntPair, struct Point, enum Color, effect Console, trait Show, foo, bar }
import ./path/to/mod.vibe { foo }
import #abc12345 { foo }
import version@main { foo }
import symbol@std/math { foo }
```

Per-item import kind:
- `foo` / `foo as alias`: value import (default)
- `type T`: type alias import
- `struct T`: struct import
- `enum T`: enum import
- `effect E`: effect import
- `trait Eq`: trait import
- A selected owner such as `struct MutMap` activates its `MutMap::...`
  namespace; importing the same unaliased members separately is redundant.
- If a non-default qualifier does not match the exported
  symbol category, compiler emits an `import` diagnostic.
- Importing a non-exported trait emits `[TROP002] non-exported trait: <Name>`.

Parser compatibility:
- `version:<name>` / `symbol:<name>` are accepted, but `@` form is canonical.

Exports are explicit:

```
export let add: (Int, Int) -> Int = (x, y) -> { x + y }
export enum Color { Red; Green; Blue }
export type IntPair = (Int, Int)
export { add, Color, IntPair }
export ./other.vibe { foo }
```

Rules:
- No implicit "export all".
- Non-exported top-level names are module-private.
- Legacy `use <module-ref> { ... }` import syntax is removed.
  `use` at import position is a parse error.
- Bare namespace shorthand (`import foo.vibe`) and default-import forms are not
  part of the current spec.

### Type-member imports and namespace binding (current)

Namespace-explicit style (ESM/Python-like) is adopted for type-attached
functions.

Current forms:

```vibe
import @vibe/builtin { type Int }             // also imports Int::*
import @vibe/builtin { Int }                  // namespace activation
import @vibe/builtin { Int::to_string }       // single member
import @vibe/builtin { Int::to_string as int_to_string }
```

Rules:
- Plain symbols and namespace symbols follow one resolution model:
  `local > lexical > explicit import > prelude`.
- `import <module-ref> { Int }` activates namespace binding `Int:: ->
  <module-ref>` in the current module scope.
- Activated `Int::` resolves `Int::*` only from the bound `<module-ref>`.
  Example: if target is `std/int`, only exported `Int::...` symbols in
  `std/int` become resolution candidates.
- `import <module-ref> { Int::name }` imports only that member from that
  `<module-ref>`.
- Namespace activation (`import <module-ref> { Int }`) also auto-forwards
  receiver-first exported functions as `Int::name` when the first argument type
  root resolves to `Int` (including enum-variant-shaped receiver types).
- Overwrite is forbidden:
  if an already-bound namespace or symbol key (`Int::` or `Int::name`) is
  bound to a different target module, it is a compile error.
- Re-importing an identical binding for the same namespace key is idempotent.

### Module refs and normalization

`import <module-ref> { ... }` accepts:
- `PathRef`: local/module path literal.
- `HashRef`: content hash literal (`#...`).
- `VersionRef`: namespace pointer.
- `SymbolRef`: symbol pointer.

Notes:
- `PathRef` is unquoted (`import ./lib/@vibe/some_local_module.vibe { ... }`).
- `import` source is semantically `ModuleRef`; non-module assets should be split to a future `AssetRef` lane.

Dependency resolution is Nix-like: path inputs are handled as typed path objects
instead of raw strings.

Normative `PathObj` shape:
- `raw`: user-written path literal.
- `base`: importer module directory.
- `normalized`: canonical path used for identity and lock lookup.

Path normalization rules:
- Resolve relative paths against importer module directory.
- Collapse `.` and `..`.
- Remove duplicated separators.
- Canonicalize separators to `/`.
- Keep semantic path components stable (no lossy rewriting of names).

### Lock and resolution flow

Resolution pipeline:

1. Parse the import: a relative path (`./x.vibe`), a package name
   (`@scope/name`), or a hash literal (`#...`).
2. A relative path resolves against the importer's directory and may not
   cross a package boundary (`index.vpkg`, ADR-0070) inward.
3. A package name resolves in order: the project's `.vibe/store/<name>/`,
   verified against the `require` pin of the importer's owning `index.vpkg`
   (the nearest enclosing one, so the root manifest covers the whole project)
   or of the importer's own head; then the workspace `lib/<name>/`; then the
   `VIBE_LIB` roots.
4. Bind imported symbols to local names.

Invariants:
- A store copy whose package hash differs from its pin is a compile error
  (`pin mismatch`); a store import with no pin anywhere is a compile error
  naming the manifest.
- The pin is the `require @scope/name x.y.z = #pkg:b3:<hex> from
  <source>@<commit>` line in the root `index.vpkg`: `vibe add <source-spec>`
  writes it and installs the package, `vibe fetch` restores the store from
  it (#2676). There is no separate lock file.
- Dependency updates are explicit workflow steps (`vibe add`, `vibe pkg
  update`), not side effects of `run` / `test` / `build`.

## Trait and impl rules (current)

```vibe
trait Eq;
trait Ord: Eq;

export trait Eq;
export open trait Ord: Eq;

impl Eq for Int;
impl [T: Eq] Eq for Array[T];
impl [T: Ord + Eq] Ord for Box[T];
```

Rules:
- Trait names are unique in an environment; duplicate definitions are errors.
- Supertraits must already be defined and cannot include the trait itself.
- `open trait` is valid only with `export` (`export open trait ...`).
- `export trait ...` is sealed outside the defining module.
- External impl against a sealed trait emits `[TROP001]`.
- External impls are allowed only for traits imported as `open`.
- `impl` type parameters must be unique.
- Bounds in `impl [T: A + B]` are deduplicated and each bound must be a known
  trait.
- Overlapping impls for the same trait are rejected.
- Overlapping impl rejection emits `[TROP003]`.
- Supertrait satisfaction is transitive (`impl Ord for T` also satisfies `Eq`
  when `trait Ord: Eq`).
- Trait imports are explicit when directly referring to trait names
  (`import ... { Eq }`, `trait Eq`, `impl Eq ...`), and only exported traits can be
  imported across modules.
- For imported value symbols with trait-bounded schemes, required exported traits
  are auto-imported for bound resolution.
- Import renaming preserves canonical source identity for supertrait checks
  (`Eq as MyEq` keeps relation to canonical `Eq`).

## Struct and enum details (current)

```vibe
// Not named `Option`: a declaration may not take a builtin type's spelling,
// because an annotation resolves that to the builtin before it looks at
// declarations (#2475).
enum Maybe[T] {
  Nothing;
  Just(T);
} derive(Eq)

struct Pair[T] {
  left: T;
  right: T;
}

let left = 1
let right = 2
let q = Pair::{ left, right } // shorthand for { left: left, right: right }
```

```vibe
struct Pair2[T] {
  left: T;
  right: T;
}

// #886: explicit type arguments pin the instantiation (arity-checked against
// the struct's declared type params; field values are checked against the
// pinned types instead of driving inference).
let p = Pair2[Int]::{ left: 1, right: 2 }
```

Rules:
- Declaration separators are `;` for both enum variants and struct fields.
  Using `,` as the separator is a parse error: the parser reports a located
  message (`use ';' to separate declaration members; ',' is not a
  separator`).
- Enum/variant constructor names must start with uppercase.
- Enum definitions must have at least one variant.
- Constructor names are globally unique in the current environment.
- Duplicate type parameters, duplicate variants, and duplicate struct fields are
  errors.
- Struct literals require all declared fields exactly once.
  Missing/unknown/duplicate fields are errors.
- Struct literal fields support shorthand: `Name::{ left, right }` is
  shorthand for `Name::{ left: left, right: right }`, matching an in-scope
  binding named after the field (same shorthand as anonymous `record { ... }`
  literals).
- Struct type arguments are inferred from the provided field expressions
  (#829). Explicit type arguments (`Pair[Int]::{ ... }`, #886) are also
  supported: the list must match the struct's declared type-parameter arity
  (mismatch is a checker error) and PINS the instantiation — field values are
  checked against the pinned types, which resolves cases inference alone
  cannot (e.g. an empty-array field: `Bag[Int]::{ xs: [] }`).
- `derive(TraitA, TraitB)` expands to corresponding `impl` entries for the
  declared type (duplicates ignored).
  Unknown traits or sealed-trait derive targets are rejected at type check.
- Enum constructor payload typing:
  - no args => `Unit`
  - one arg => that type
  - multiple args => tuple payload

## Placeholder lambda shorthand (advanced)

<!-- doctest-skip: 未定義名 (map / xs / add / zip_with / ys / f) を参照する desugar 提示の断片 -->
```vibe skip
map(xs, add(_, 1))        // => map(xs, (__p0) -> add(__p0, 1))
zip_with(xs, ys, f(_, _)) // => zip_with(xs, ys, (__p0, __p1) -> f(__p0, __p1))
```

Rules:
- `_` is parsed as a placeholder expression.
- Placeholder desugaring runs on call arguments (`Expr::Call` arg expressions).
- Placeholders are reindexed left-to-right and replaced with generated params
  (`__p0`, `__p1`, ...).
- Desugaring does not cross block/lambda boundaries.
- A placeholder that survives desugaring is a type error
  (`placeholder _ can only be used in function arguments`).
- This feature is intentionally excluded from the standard tutorial path.

## Member access, indexing, and pipe calls (current)

<!-- doctest-skip: 未定義名 (obj / t / arr / x / f / g) を参照する構文提示の断片 -->
```vibe skip
obj.field             // data member access
t.0                   // tuple index
arr[i]                // => __index(arr, i)
(obj.method)(arg)     // function-value field call
x |> f                // shorthand of x |> f()
x |> f(a, b)          // => f(x, a, b)
```

Rules:
- Postfix chains are parsed left-to-right.
- `.` is used for data member access (`struct`/`record`) and tuple index
  access (`.0`, `.1`, ...).
- A declared user-type method may be called as `recv.method(args)`; its
  canonical normalized spelling is `Type::method(recv, args)`. The single-file
  normalizer applies that rewrite only when it can recover the receiver's type
  from local declarations, annotations, or constructors; otherwise it leaves
  the dot call unchanged rather than guessing.
- Builtin APIs use qualified calls (for example `String::length(s)`) or pipe
  style; builtin receiver dot-call sugar is not available.
- A function stored in a field is not a method: invoke it as
  `(obj.callback)(args)`.
- `expr[index]` desugars to `__index(expr, index)`.
- `|>` is object-lane call desugaring:
  - `x |> f` is shorthand of `x |> f()`
  - `x |> f(a, b)` desugars to `f(x, a, b)`
  - chained pipe is left-associative
- `|>` desugaring is performed in parser AST construction.
  evaluator/codegen layers assume already-desugared call form.
- Expressions that mix `|>` with other infix operators without explicit
  parentheses are parse errors.
  - example error: `1 + 1 |> double`
  - allowed: `(1 + 1) |> double`

### Type-qualified namespace symbols (current)

`Type::symbol` is the canonical human-facing namespace form.

Declaration examples:

```vibe
let Int::to_string: (Int) -> String = (x) -> { "int" }
let String::to_string: (String) -> String = (x) -> { x }
export let Option::unwrap_or: [T](Option[T], T) -> T = (opt, fallback) -> {
  match opt {
    Some(v) => v
    None => fallback
  }
}
```

Rules:
- Canonical separator is `::` (`Type::symbol`).
- Namespace symbols are normal function symbols (not trait syntax).
- Namespace functions are declared with `let Type::symbol = ...`
  (or equivalent declaration form).
- `impl` is reserved for trait implementations (`impl Trait for Type`).
- Name resolution is unified for plain symbols and namespace symbols:
  `local > lexical > explicit import > prelude`.
- `Type::symbol` participates in normal named import/export.

Import/export example:

<!-- doctest-skip: 存在しない import 先 (./std/stringify.vibe) を参照する構文例 (#831 の crash 経路) -->
```vibe skip
export { Int::to_string, String::to_string }
import ./std/stringify.vibe { Int::to_string as int_to_string }
```

Normalization and internal identity:
- fully-qualified canonical symbol:
  `/pkg@version/module/Type::symbol`
- internal address ref:
  `<canonical-symbol>#<addr-hash>`

Example:
- `/vibe/builtin@0.0.1/func/compose`
- `/vibe/builtin@0.0.1/func/compose#9b1f...`

### Prelude and `--nostd` (current)

- Default mode preloads prelude symbols, including namespace members.
- `--nostd` disables all implicit prelude imports.
- In `--nostd`, namespace members must be imported explicitly.

## while / break / continue (current)

<!-- doctest-skip: 構文列挙の断片 (bare break/continue は loop 外、cond/step 未定義) -->
```vibe skip
while cond {
  step()
}

break
continue
```

Rules:
- `while` condition must be `Bool`.
- `while` body is type-checked, and the expression result type is always `Unit`.
- `break` and `continue` are valid only inside loop bodies.
- `while`, bare `loop { ... }`, and `for-in` accept only bare `break`. `while`
  and bare `loop` return `Unit`; `for-in` returns its collected prefix.
- Only parameterized `loop (...)` accepts `break value`; the payload must begin
  on the same line as `break`.
- Using `break`/`continue` outside a loop is a type error.
- Runtime loop control uses `break` to exit the nearest loop and `continue` to
  start the next iteration.
- `yield` is a reserved keyword and the parser refuses it (`'yield' is not
  supported`); there is no generator form.
- Errors travel as the `Exception` effect; `Result` was removed from the
  language in #1324.
- Error boundary syntax is `handle { ... } with Exception { Throw(_) => ... }`.

## Test blocks

```
test {
  let x = 1
}
```

Notes:
- `test { ... }` is parsed and type-checked but excluded from content hashing.
- Tests run under `vibe test`; `vibe run` ignores them.
- Optional name form: `test "name" { ... }` (label only).
- A runtime expectation is an `inspect(value, content)` snapshot inside the
  block; `vibe test --update` rewrites a stale expected literal to the actual
  value (#1571). A compile rejection is classified by verdict and message in
  `fixtures/typecheck/expected.tsv`. No fixture carries a `__DATA__` tail;
  `scripts/check_fixture_snapshots.mjs` rejects one.

CLI:
- The canonical compiler / checker / CLI implementation lives under `lib/@vibe/compiler/`
  and `lib/@vibe/cli/` (selfhost-only; the MoonBit `src/cmd/*` host was retired in #594).
- Commands below use the installed `vibe` binary; from a checkout the equivalent is
  `pkf run run -- <args>`.
- `vibe run <file>` executes a script (ignores `test {}`).
- `vibe test <file|dir...>` runs test blocks and prints a report. A directory expands to every `*_test.vibe` under it.
- `vibe compile [--wasm | --wit] [-o out] <file>` emits wasm bytes (the default)
  or, with `--wit`, the WIT world of the file's effect surface.
  - `--wasm` = linear-memory backend (production default). `--wasm-gc` is not yet
    wired into the compile CLI (throws); the gc backend is reachable via
    `VIBE_TEST_BACKEND=gc` / `VIBE_BENCH_BACKEND=gc` for pure test/bench. The
    other output modes of the retired MoonBit host (`--wasm-js-string`,
    `--component`, `--wit-component`, `--wac`, `--compose-p3`) are refused with
    a message naming the flag; see `cli-commands.md`.
- `vibe shell [file.vibe]` is a compiled REPL (ADR-0034, no interpreter): the
  session is a buffer of top-level declarations, and every line recompiles it
  through the same path as `vibe run`.
- `pkf run component-run -- script.vibe` builds a stdio-capable component and runs it via wasmtime (`--invoke 'run()'`).
- `pkf run component-run-moonix -- script.vibe` builds the same component and runs it via moonix.
- `bash install/install.sh` installs the CLI (see `docs/user/getting-started/install.md` for the toolchain layout; `VIBE_HOME` / `VIBE_BIN_DIR` choose where).
- Imports are loaded recursively (imports of imports) for hashing and import-rename resolution.

Bench:
- `bench "name" { ... }` in a `.vibe` file; `vibe bench <file.vibe> [--iters N] [--warmup N]`
  runs the blocks and reports ns/op (min / p50 / p95 / mean), ops/sec and
  bytes/op (from a checkout: `pkf run run -- bench <file.vibe>`).
- The linear backend is the default; `VIBE_BENCH_BACKEND=gc` runs the same file
  on wasm-gc (pure benches only, no host imports).
- Compiler micro-benchmarks are ordinary `bench {}` files passed to `vibe bench`
  (`lib/@vibe/compiler/checker_bench.vibe` / `codegen_bench.vibe` /
  `fmt_bench.vibe`; the stdlib's live under `bench/`). The pkf bench tasks that
  remain are `bench-compile-hotspots` and `bench-module-job-pool`.

## Pure result cache (Unison-style)

Pure function results are cached by content-derived keys.

- Cache entries are **not** included in module content hashes.
- Cache snapshots live in a separate file and are loaded externally.
- Snapshot format is line-based: `<hash>\\t<encoded-value>`.

## Canonical S-expression IR (current serializer output)

Current hash input is the exact output of `module_to_sexp`:

```sexp
(module (stmts ...))
```

There are no top-level `def/id/global/self` nodes in the current serializer.
Module identity is computed outside the IR text as Git blob `sha1`.

### Statement forms

```sexp
(let "name" <expr>)
(let-rec "name" <expr>)
(expr <expr>)
(enum "Name" (params "T" ...) (ctors (ctor "Some" <type>) ...))
(type-alias "Name" (params "T" ...) <type>)
(export-let "name" <expr>)
(export-let-rec "name" <expr>)
(export-enum "Name" (params ...) (ctors ...))
(export-type-alias "Name" (params ...) <type>)
(let-mut "name" <expr>)
(assign "name" <expr>)
(index-assign <expr> <expr> <expr>)
(let-pat <pat> <expr>)
(struct "Name" (params ...) (fields (field "x" <type>) ...))
(export-struct "Name" (params ...) (fields ...))
```

Current hashing behavior for statements:
- `Import`, `Export`, `ReExport`, `Test`, `TraitDef`, `TraitImpl` are omitted.
- `Span`/location info is omitted.

### Expression forms

```sexp
(lit (int 1))
(lit (float 1.0))
(lit (double 1.0))
(lit (bool true))
(lit (string "abc"))
(ref "name-or-qualified-name")
(call "callee" (args (arg _ <expr>) (arg "label" <expr>) ...))
(if <expr> (block (stmts ...)) (block (stmts ...)))
(block (stmts ...))
(match <expr> (arms (arm <pat> (guard <expr>)? <expr>) ...))
(tuple <expr> ...)
(tuple-index <expr> 0)
(record (field "k" <expr>) ...)
(struct-lit "Type" (field "k" <expr>) ...)
(array <expr> ...)
(map (field "k" <expr>) ...)
(handle (block (stmts ...)) (arms (arm <pat> (guard <expr>)? <expr>) ...))
(fn (params (param "x" pos <type>) ...) (ret <type>|_) (effects <eff> ...) (block (stmts ...)))
(while <expr> (block (stmts ...)))
(throw <expr>)
(yield <expr>)
```

### Pattern forms

```sexp
(pat _)
(pat (bind "x"))
(pat (ctor "Some" <pat> ...))
(pat (tuple <pat> ...))
(pat (record (field "k" <pat>) ...))
(pat (struct "Type" (field "k" <pat>) ...))
(pat (int 1))
(pat (float 1.0))
(pat (double 1.0))
(pat (bool true))
(pat (string "x"))
(pat (or <pat> ...))
```

### Type forms

```sexp
Int | Float | Double | Bool | String | @core.Path | Unit
(Named "Option" <type> ...)
(Param "T")
(Var 1)
(Tuple <type> ...)
(Record (field "k" <type>) ...)
(Variant (ctor "Some" <type>) ...)
(Array <type>)
(Map <type>)
(ArrayBuilder <type>)
(MapBuilder <type>)
(Func (params (param "x" pos <type>) ...) (ret <type>) (effects <eff> ...))
```

### Canonicalization rules (current)

- Import sources are resolved to hash refs before IR generation.
- Alias resolution is applied to identifier/callee references (`ref`/`call`).
- Record/map/record-type/variant ctor and enum ctor ordering is canonicalized.
- Tests and import/export metadata are excluded from hash input.
- `i32`/`f32`/`f64` surface aliases normalize to `Int`/`Float`/`Double`.

## Compile + run

- `compile_module(db, path)`:
  - parse + type check
  - desugar + monomorphize AST
  - rewrite imports to hash refs
  - serialize canonical S-expression IR
  - compute Git blob `sha1` and module ref
- Public execution path (`vibe run` / `vibe test` / `vibe shell`):
  - uses compiled execution as the default surface
  - prepares host runtime state (for example type/import metadata) around the
    generated module before execution

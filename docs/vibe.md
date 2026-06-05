# vibe language specification

This document captures the current vibe design: a Rust/MoonBit-like, statically
typed, pure functional language with explicit effects, built for WASM/wasip3.

## Status and authority

- `docs/spec/syntax.md` is the canonical surface syntax reference.
- `docs/vibe.md` is the broader language design/spec note for implemented
  behavior outside pure syntax (effects, imports, hashing, runtime contracts).
- Items explicitly marked as "future", "proposal", or "draft" are non-normative.
- Design explorations live in separate documents:
  - `docs/module-system.md`
- Incident log for compiler/language regressions:
  - `docs/compiler_language_incidents.md`

## Goals

- POSIX sh superset with a clear syntactic split.
- Pure by default; effects are explicit (`with { ... }`) and can be locally
  handled with effect handlers (`handle eff { ... }` pattern arms).
- Content-addressed functions (Git blob compatible) with Unison-style aliases.
- Incremental pipeline: CST -> AST -> monomorphized AST -> canonical S-expression -> hash.

## Syntax dispatch

Parser dispatch is explicit:
- parser-consuming CLI commands accept `--syntax vibe`.
- default is `--syntax vibe`.
- static/compile-oriented commands (`check`, `test`, `compile`, `hash`, `save`,
  `fetch`, `update-lock`, `bench-file`, `wasm-shell-stdin`) remain vibe-only.
- non-`vibe` syntax values are rejected by the public CLI.
- Internal PosixMode preprocessing/desugar remains available for
  shell-style command-head preview (`ls` -> `sh_lines("ls")`).
- In internal `PosixMode`, each unresolved bare identifier command-head rewrite
  emits a runtime note (`note: posix-mode command-head desugar: ...`) so
  migration behavior is explicit in `run`/`shell-stdin` output.

Reserved leading keyword detection (`let`, `fn`, `type`, `effect`, `import`,
`test`, `handle`, `throw`) exists as helper logic only and does not switch parser modes.
`fn` is not a current declaration form.
- `map` is not a reserved keyword and can be used as a normal identifier.

## Standard tutorial scope (v1 core)

Included in standard tutorial:
- core expressions/statements: `let`, `if`, `match`, `while`
- module API: `import` / `export`
- data model: `enum` / `struct` / tuples / arrays / records
- error flow: `Result` composition (`map`, `and_then`, `match`)
- effects: explicit `with { ... }`
- effect handling: `handle` arms for effect/local error pattern matching

Documented but excluded from standard tutorial:
- placeholder lambda shorthand (`_` in call arguments)
- raw identifiers (`r#name`)
- boundary-style exceptions (`throw`)
- local mutation (`let mut`), `Ref[T]` abandoned (→ ADR-0021)
- PosixMode command-head desugar and unstable runtime flags

## Effects

Effects are explicit in function signatures and validated by effect
compatibility plus handler matching.

```
let run: () -> Unit with { Stdout } = () -> {
  sh("ls")
}
```

Rules:
- Effect signature requirement:
  a function's declared effects must be a superset of the effects used inside.
  (`with { ... }` is the capability contract.)
- Handler requirement:
  effects can be localized by `handle` arms that pattern-match the handled
  operation/error payload.
- `with {}` is optional; omission means pure.
- `do` is not part of the current surface syntax.
- Capability mapping is 1:1 with the runtime `CapabilitySet`.
- Current builtin mapping:
  - `sh(...)` requires `{Stdout}`
  - `sh_lines(...)` requires `{Stdout}`
  - `Stdout::write_char(...)` requires `{Stdout}`
  - `Stdout::write_stream(...)` requires `{Stdout}`
  - `Stdin::read_char()` requires `{Stdin}`
  - `Stdin::read_stream(...)` requires `{Stdin}`
  - `sleep(...)` requires `{Async}`
- Runtime gate (current CLI behavior):
  - `sleep(...)`, `yield` execution is disabled by default.
  - enable with `--unstable-async` (`vibe run/test/shell/bench ...`).
  - `Threads::probe_wat()` execution is disabled by default.
  - `Threads::runtime_hints()` execution is disabled by default.
  - enable with `--unstable-threads`.

Examples:

```vibe
// ok: declared effect allows direct builtin call
let run: () -> Unit with { Stdout } = () -> { sh("ls") }

// error: missing effect declaration for direct effectful builtin call
let run: () -> Unit = () -> { sh("ls") }

// error: caller must include callee effect
let f: (Int) -> Int with { Error } = (x) -> { x }
let g: (Int) -> Int = (y) -> { f(y) }

// ok: effect requirement is explicitly propagated
let g2: (Int) -> Int with { Error } = (y) -> { f(y) }

// ok: effect is localized by handler pattern
let g3: (Int) -> Int = (y) -> {
  handle { f(y) } with Error { Throw(_) => 0 }
}
```

### Error model (Result-first, current policy)

- Standard error model is `Result[T, E]`.
- Application/core pipelines should compose with `Result` (`map`,
  `and_then`/`bind`, `map_err`).
- `throw` is an advanced boundary mechanism and should be isolated at adapters
  (CLI/HTTP/FFI/tests).
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

let fail: () -> Result[Unit, AppError] = () -> {
  Err(Io("io"))
}
```

Railway-oriented guideline (pipe-first error flow):
- pipeline core should stay in `Result` composition (`Result::and_then`,
  `Result::map_ok`, `Result::map_err`).
- terminal boundaries (`match`, project-local `unwrap`, optional `handle`/`throw`) should be
  isolated at adapter edges (CLI/HTTP/FFI/tests).
- avoid scattering multiple implicit boundaries across one flow; make the
  boundary location explicit in code.

```vibe
let run_core: (String) -> Result[Int, String] = (raw) -> {
  raw
  |> parse_id
  |> Result::and_then(validate_id)
  |> Result::and_then(load_user_id)
}

let run_cli: (String) -> Int = (raw) -> {
  match run_core(raw) {
    Ok(v) => v,
    Err(_) => -1
  }
}
```

### Generics with effects (current)

Effect polymorphism and type polymorphism are checked together.

Rules:
- Effect row variables (for example `with {e}`) can appear with generic type
  parameters in higher-order function signatures.
- At call sites, type variables and effect variables are instantiated together.
- If a callee's effect requirement escapes through a wrapper, the wrapper must
  declare a compatible effect set.
- Trait bounds and effect checks are independent constraints; either can fail
  first depending on the call shape.

Examples:

```vibe
// error: wrapper body calls effect-polymorphic callback without declaring {e}
let apply: [T](f: (T) -> T with { e }, x: T) -> T = (f, x) -> {
  f(x)
}

// ok: wrapper propagates effect requirement explicitly
let apply_ok: [T](f: (T) -> T with { e }, x: T) -> T with { e } = (f, x) -> {
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

> **Note**: `Ref[T]` は ADR-0017 で当初 accepted だったが、ADR-0021 の
> Effect Handler で設計意図を代替する方針に変更され **abandoned** となった。
> ミュータブル参照の安全な抽象化は `effect Mut<T>` で提供する計画
> (ADR-0021 参照)。

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

String (aligned with wasm js-string builtins when using `--wasm-js-string`):
- `String::length(string)` -> `Int`
- `String::char_code_at(string, index)` -> `Int`
- `String::from_char_code(code)` -> `String`
- `String::substring(string, start, end)` -> `String`
- `String::concat(left, right)` -> `String`
- `String::equals(left, right)` -> `Bool`

StdIO (wasi stream primitives for wasm/component-friendly interop):
- `sh_lines(cmd)` -> `Array[String]` with `{Stdout}`.
  Current host runtime executes a builtin command subset (`ls`, `cat`, `echo`)
  and returns output lines while also recording `ShellExec(cmd)` effect.
- `Stdout::write_char(code)` -> `Unit` with `{Stdout}`
- `Stdout::write_stream(text)` -> `Unit` with `{Stdout}` (chunk write)
- `Stdin::read_char()` -> `Int` with `{Stdin}` (`-1` = EOF)
- `Stdin::read_stream(max-bytes)` -> `String` with `{Stdin}` (`""` = EOF/error)
- component WIT/wasm import mapping:
  - `Stdout::write_char` -> `wasi:cli/stdout@0.2.0#get-stdout` + `wasi:io/streams@0.2.0#[method]output-stream.blocking-write-and-flush`
  - `Stdout::write_stream` -> same as `Stdout::write_char` (single host call for whole chunk)
  - `Stdin::read_char` -> `wasi:cli/stdin@0.2.0#get-stdin` + `wasi:io/streams@0.2.0#[method]input-stream.blocking-read`
  - `Stdin::read_stream` -> same as `Stdin::read_char` (cabi read-buffer -> vibe string)

Threads (experimental, runtime-gated by `--unstable-threads`):
- `Threads::probe_wat()` -> `String`
- `Threads::runtime_hints()` -> `{ wasm_flags: Array[String], wasi_flags: Array[String], wasm_env: String, wasi_env: String }`
- `Threads::channel_new(capacity: Int)` -> `ThreadChannel[T]`
- `Threads::send(channel: ThreadChannel[T], payload: T)` -> `Bool`
  - current experimental payload lowering supports `Int` and `String`
- `Threads::recv(channel: ThreadChannel[T])` -> `T`
- `Threads::spawn(name: String, channel: ThreadChannel[T])` -> `ThreadTask[R]`
  - for supported string-literal workers, `R` is the worker return type
  - current experimental worker result lowering supports `Int`, `String`, and
    `Array[Int]`
  - reserved diagnostic names currently return `ThreadTask[Int]`
- `Threads::wait(task: ThreadTask[T])` -> `T`
  - `linear-local` currently returns `0`
  - `component-unsafe-os-threads` reads the 64-bit tagged slot payload and
    surfaces worker results through `ThreadTask[R]`
- `ThreadChannel[T]` is a checker-level payload contract. The current compiled
  ABI still stores and passes the channel handle as the existing tagged `Int`
  value, but `send` and `recv` must agree on `T`. Under
  `component-unsafe-os-threads`, shared channel payload cells store the full
  64-bit tagged Vibe value with `i64.atomic.store`/`i64.atomic.load`.
- `ThreadTask[T]` is a checker-level result contract. The current compiled ABI
  still stores and passes the task handle as the existing tagged `Int` slot
  pointer, but `Threads::wait` no longer accepts arbitrary `Int` values at the
  source type layer.
- `linear-local` compiled lowering is deterministic and not parallel:
  `channel_new` creates an in-module single-slot channel, `send` overwrites the
  slot, `recv` consumes it, `spawn` returns a completed task handle, and `wait`
  returns `0`.
- `component-unsafe-os-threads` currently lowers `channel_new`/`send`/`recv`
  to shared memory plus atomic field operations for the generated component
  staging path.
  `spawn`/`wait` use the Vibe slot ABI with `canon thread.spawn-indirect`,
  `memory.atomic.notify`, and `memory.atomic.wait32` on the local
  `mizchi/wasmtime` fork when `WASMTIME_UNSAFE_COMPONENT_THREAD_OS_SPAWN=1` is
  set. The returned task handle is a Vibe-owned slot pointer and must not be treated
  as a canonical `thread.spawn-*` join/result handle.
- `component-unsafe-os-threads` rejects `enable_rc=true` for now. The current
  Perceus/RC free-list path is not part of the shared-thread heap contract; only
  the backend's atomic bump allocation path is covered by the current probes.
- `component-unsafe-os-threads` shared atomic bump allocation returns at least
  4-byte aligned Vibe heap object pointers. Shared channel cells and component
  task slots that contain `i64.atomic.load/store` payload fields are allocated
  with 8-byte alignment.
- Builder grow and bulk grow do not use the heap-tip in-place fast path under
  `component-unsafe-os-threads`; they allocate replacement storage through the
  shared atomic allocator.
- `cabi_realloc` uses a shared-memory CAS loop in
  `component-unsafe-os-threads`, so canonical ABI power-of-two alignment
  requests reserve aligned ranges from the same shared cursor.
- `scripts/wasm_vibe_host_runner.js` refuses the legacy `__heap_ptr` Preview2
  allocation fallback when exported memory is shared; shared-memory host
  allocation must go through exported `cabi_realloc`.
  String-literal worker dispatch is currently limited to reserved diagnostic
  names (`"noop"`, `"alloc-probe"`) or capture-free top-level worker functions
  in the temporary `ThreadChannel[Int|String] -> Int|String|Array[Int]` shape.
  Dynamic worker names are rejected in this backend until function-value,
  closure, or richer payload/result semantics are specified.
- `vibe/prelude/threads.vibe` は test-safe な pure contract 層を分離:
  - `task_spec`, `channel_spec`, `actor_spec`, `deployment_plan`, `recommended_*`
  - これらは通常 `vibe test` で実行可能
  - runtime 呼び出し
    (`probe_wat`, `runtime_hints`, `channel_new`, `spawn`, `send`, `recv`, `wait`)
    のみ `--unstable-threads` 必須

Generated contract table:
- `docs/builtin_contract_table.generated.md`
- regenerate with: `node scripts/gen_builtin_contract_table.mjs`

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

```vibe
import ./path/to/mod.vibe { foo, bar as b }
import ./path/to/mod.vibe { type IntPair, trait Show, foo, bar }
import ./path/to/mod.vibe { foo }
import #abc12345 { foo }
import version@main { foo }
import symbol@std/math { foo }
```

Per-item import kind:
- `foo` / `foo as alias`: value import (default)
- `type T`: type import (type alias / enum namespace)
- `trait Eq`: trait import
- `type Int` can be used as namespace activation for `Int::...` exports.
- If a non-default qualifier (`type` / `trait`) does not match the exported
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
import ./vibe/prelude/int.vibe { type Int }             // also imports Int::*
import ./vibe/prelude/int.vibe { Int }                  // namespace activation
import ./vibe/prelude/int.vibe { Int::to_string }       // single member
import ./vibe/prelude/int.vibe { Int::to_string as int_to_string }
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
- `PathRef` is unquoted (`import ./vibe/prelude/string.vibe { ... }`).
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

1. Parse `module-ref` (`PathRef`/`HashRef`/`VersionRef`/`SymbolRef`).
2. For `PathRef`, build `PathObj` and load source by `normalized` key.
3. Resolve to hash:
   - `PathRef`: compute content hash and store/read `__hash__/<hash>`.
   - `HashRef`: read/verify `__hash__/<hash>`.
   - `VersionRef`: lookup `__ref__/version/<name>` then resolve hash snapshot.
   - `SymbolRef`: lookup `__ref__/symbol/<name>` then resolve hash snapshot.
4. Rewrite import source to `HashRef` for compiled/eval paths.
5. Bind imported symbols to local names.

Invariants:
- Runtime evaluation uses locked hash refs only.
- Missing required lock metadata or hash mismatch is a compile error.
- Dependency updates are explicit workflow steps (`apply`/`check`/`fetch`/`update-lock`),
  not implicit side effects during execution (`run`/`eval`).

Current lock file:

- `index.lock` (JSON object) is loaded from the resolved index root directory.
  - `index.vdb` is checked first; when it includes lock payload
    (`path`/`version`/`symbol`/`module`/`annotation` or `lock` object),
    that payload is used as lock source.
  - If `index.vdb` has no lock payload, loader falls back to `index.lock`.
  - Legacy compatibility: if `index.lock` is absent and `vibe.lock` exists in the
    same directory, loader reads `vibe.lock`.
- Shape:
  - `path`: `{ "<path-key>": "<hash>" }`
  - `version`: `{ "<name>": "<hash>" }`
  - `symbol`: `{ "<name>": "<hash>" }`
  - `module`: `{ "<normalized-path>#<export-name>": "<normalized-export-hash>" }`
  - `annotation`: `{ "<key>": "<note-text>" }`
- `path` keys are written as lock-dir-relative paths (`./foo.vibe`) and resolved
  to normalized absolute paths when loading (absolute keys are also accepted).
- Root guard:
  - index root is the nearest ancestor directory containing `index.vibe`
    (fallback: entry directory).
  - `index.vibe` must export version:
    `export let version = "0.0.1"` (simple semver `x.y.z`).
  - Path imports are rejected when resolved path escapes index root.
  - `index.vibe` may define `export let module = record { <ns>: "<dir>" }` to map
    namespace imports (for example `std/...`) under root.
  - Default namespace mapping includes `builtin -> ./vibe/prelude`.
- CLI:
  - `vibe apply <entry>` resolves recursive path imports, updates `index.lock`,
    injects prelude refs, and updates `index.vdb.graph_head`.
    It also stores the graph snapshot object under `.vibe/objects/<graph-head>`.
  - `vibe fetch <entry>` (or `vibe update-lock <entry>`) resolves recursive
    path imports and updates `index.lock`.
  - `fetch/update-lock` also injects prelude refs:
    - `version.prelude = <normalized-prelude-hash>`
    - `symbol."std/prelude" = <normalized-prelude-hash>`
    and stores the normalized prelude module object under `.vibe/objects/`.
  - `vibe check <entry...>` runs the same resolution/apply pipeline as `vibe apply`
    before diagnostics.
  - `vibe run/compile/test` require lock entries for path imports;
    missing/mismatch emits import diagnostics and fails compile.

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
enum Option[T] {
  None;
  Some(T);
} derive(Eq)

struct Pair[T] {
  left: T;
  right: T;
}

let p = Pair[Int]::{ left: 1, right: 2 }
let q = Pair::{ left, right } // shorthand for { left: left, right: right }
```

Rules:
- Declaration separators are `;` for both enum variants and struct fields.
  Commas are parse errors in declarations.
- Enum/variant constructor names must start with uppercase.
- Enum definitions must have at least one variant.
- Constructor names are globally unique in the current environment.
- Duplicate type parameters, duplicate variants, and duplicate struct fields are
  errors.
- Struct literals require all declared fields exactly once.
  Missing/unknown/duplicate fields are errors.
- Struct type arguments can be explicit (`Pair[Int]::{ ... }`) or inferred from
  provided field expressions.
- `derive(TraitA, TraitB)` expands to corresponding `impl` entries for the
  declared type (duplicates ignored).
  Unknown traits or sealed-trait derive targets are rejected at type check.
- Enum constructor payload typing:
  - no args => `Unit`
  - one arg => that type
  - multiple args => tuple payload

## Placeholder lambda shorthand (advanced)

```vibe
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

```vibe
obj.field             // data member access
t.0                   // tuple index
arr[i]                // => __index(arr, i)
(obj.method)(arg)     // function-value field call
x |> f                // shorthand of x |> f()
x |> f(a, b)          // => f(x, a, b)
```

Rules:
- Postfix chains are parsed left-to-right.
- `.` is limited to data member access (`struct`/`record`) and tuple index
  access (`.0`, `.1`, ...).
- `recv.method(...)` method-call sugar is not part of current syntax.
- Function-value field calls must be written as `(obj.method)(...)`.
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

```vibe
export { Int::to_string, String::to_string }
import ./std/stringify.vibe { Int::to_string as int_to_string }
```

Normalization and internal identity:
- fully-qualified canonical symbol:
  `/pkg@version/module/Type::symbol`
- internal address ref:
  `<canonical-symbol>#<addr-hash>`

Example:
- `/vibe/builtin@0.0.1/result/Result::and_then`
- `/vibe/builtin@0.0.1/result/Result::and_then#9b1f...`

### Prelude and `--nostd` (current)

- Default mode preloads prelude symbols, including namespace members.
- `--nostd` disables all implicit prelude imports.
- In `--nostd`, namespace members must be imported explicitly.

## vibe shell command pipeline (PosixMode preview)

```vibe
let run: () -> Array[String] with { Stdout } = () -> {
  ls |> where((line) -> { String::contains(line, "vibe") })
}
```

Rules:
- In `PosixMode`, unresolved bare identifier expressions are desugared to
  `sh_lines("<ident>")`.
- Bound names (`let`, function params, pattern bindings, imported names) are
  preserved and not desugared as commands.
- `where(xs, pred)` is available in prelude for `Array[String]` stream-style
  filtering.

## while / break / continue / yield (current)

```vibe
while cond {
  step()
}

break
continue
yield value
```

Rules:
- `while` condition must be `Bool`.
- `while` body is type-checked, and the expression result type is always `Unit`.
- `break` and `continue` are valid only inside `while` loop bodies.
- Using `break`/`continue` outside `while` is a type error.
- Runtime loop control uses `break` to exit the nearest loop and `continue` to
  start the next iteration.
- `yield expr` requires `{Async}` and returns `Unit`.
- Runtime execution for `yield` is gated by `--unstable-async`
  (disabled by default in CLI entrypoints).
- Result-first policy remains canonical for application/core flows.
- Error boundary syntax is `handle { ... } with Error { Throw(_) => ... }`.

## Test blocks (MoonBit-style)

```
test {
  let x = 1
}
```

Notes:
- `test { ... }` is parsed and type-checked but excluded from content hashing.
- Tests are intended to be executed by a separate test runner; normal evaluation ignores them.
- Optional name form: `test "name" { ... }` (label only).
Runtime API:
- `Runtime::run_script_tests(script)` parses, type-checks, and runs tests with isolated envs.
- Internal PosixMode preprocessing/desugar remains available for preview
  shell-style command-head rewriting in runtime tests.
CLI:
- `moon run --target native src/cmd/vibe -- run <file>` executes a script (ignores `test {}`).
- `moon run --target native src/cmd/vibe -- eval ...` was removed from the public CLI.
  Interactive evaluation now lives under compiled `shell` / `shell-stdin`.
- `moon run --target native src/cmd/vibe -- test <file...>` runs test blocks and prints a report.
- `moon run --target native src/cmd/vibe -- compile [--wasm | --wasm-js-string] [-o out] <file>` emits IR (default) or wasm bytes.
- `moon run --target wasm src/cmd/vibe_compile_wasi -- [compile] [--wasm|--wasm-mvp|--wasm-js-string|--wasm-gc|--component|--wit|--wit-component] [-o out] <file>` runs compile pipeline from wasm target as well.
  - `vibe_compile_wasi` only: `--wasm` prefers `wasm-gc`; use `--wasm-mvp` for core wasm backend (broader language coverage).
  - selfhost compiler boundary: compile logic stays in `vibe/compiler/*`; filesystem / environ / stdio stay in the host wrapper (`src/cmd/vibe_compile_wasi`). See ADR-0028.
- Public CLI parser-consuming commands support `--syntax vibe` only.
- `moon run --target native src/cmd/vibe -- shell` launches the TUI interactive shell (completion + layout, history).
- `moon run --target native src/cmd/vibe -- shell-stdin [--no-prompt]` reads lines from stdin and evaluates them.
- `moon run --target native src/cmd/vibe -- wasm-shell-stdin [--no-prompt] [-o dir]` compiles each entered line to a separate WASM file for pipeline testing.
- `moon build --target wasm src/cmd/vibe_compile_wasi` builds wasm compiler CLI (filesystem side is abstracted via `src/io.FileSystemAdapter`).
- `just component-run script.vibe` builds a stdio-capable component and runs it via wasmtime (`--invoke 'run()'`).
- `just component-run-moonix script.vibe` builds the same component and runs it via moonix.
- `just bootstrap-moonix [src]` tries to produce `moonix` binary from a local moonix checkout.
- TUI completion sources: builtins + PATH commands + history.
- `just install` installs a native binary to `~/.local/bin/vibe` (override with `VIBE_PREFIX`).
- Imports are loaded recursively (imports of imports) for hashing and import-rename resolution.
- Import cycle reporting is implemented for path-based import graphs
  (diagnostic stage: `import`, message prefix: `import cycle:`).

Fixtures:
- `fixtures/*.vibe` include a `__DATA__` JSON block and are executed by `moon test`.
- Fields:
  - `last`: expected `Value::to_string()` (exact match).
  - `effects`: expected `Effect::to_string()` list (exact match).
  - `error_contains` / `compile_error`: substring match for failures.
  - `TODO`: test must fail; passing means the TODO should be removed.
  - `skip`: skip the fixture.
  - `version_refs`: optional map `{ "<name>": "<hash-or-path>" }` to seed
    `version@<name>` in fixture evaluation.
  - `symbol_refs`: optional map `{ "<name>": "<hash-or-path>" }` to seed
    `symbol@<name>` in fixture evaluation.
    `"<hash-or-path>"` accepts a raw hash (`40` hex chars), `#<hash>`, or a
    module path whose content hash is used.

Bench:
- `just bench-wasmtime` builds `cmd/vibe`, compiles `bench/bench_simple.vibe` to wasm,
  then benchmarks `wasmtime run --invoke _start`.
- `just bench-compare` compares source `vibe run` vs `wasmtime run`.
- `just bench-kpi [<file|dir...>]` runs `vibe bench` and writes a combined KPI report
  (`per_us` + `wasm_bytes`) to `dist/bench_kpi/latest.tsv`.
  - Default target (no args): `bench/kpi_bench.vibe` with numeric pipeline/state-mix cases.
  - Default iterations/warmup: `compiled=20000/1000`.
  - `VIBE_BENCH_KPI_N` / `VIBE_BENCH_KPI_WARMUP` to tune iterations.
  - Optional thresholds: `VIBE_BENCH_KPI_MAX_PER_US`,
    `VIBE_BENCH_KPI_MAX_WASM_BYTES`, `VIBE_BENCH_KPI_MAX_SCORE`.
- 言語組み込み benchmark:
  - `bench "name" { ... }` を `.vibe` に書き、`vibe bench <file|dir...>` で実行。
  - backend の canonical surface は `--backend compiled`（`--backend wasm` は互換 alias）。
  - ディレクトリ指定時は top-level の `*_bench.vibe` を探索。
  - `--n` / `--warmup` は benchmark 実行回数に適用。
  - compiled bench path はサイズ優先で `--no-dce -Oz` 相当のコンパイルを使い、出力に `wasm_bytes=<size>` を含める。
- 互換の expression benchmark モード（legacy）:
  - legacy expr mode (`--expr`, `--case`, `--cases`) は廃止
  - `bench {}` を含む `.vibe` file を `vibe bench <file>` で実行する
- `vibe index ref push <scope> <index-file>` / `pull <scope> <out-file>` maps advanced graph snapshots to git/bit refs under
  `refs/bit/index/<scope>/graph/head`.
- `vibe index ref push-delta <scope> <delta-file>` / `pull-delta <scope> <out-file>` maps advanced graph deltas to
  `refs/bit/index/<scope>/graph/wal_head`.
- `just bench-cmd-latency` is a backward-compatible alias of `just bench-compare`.
- `just bench-scratch-workflow` benchmarks scratch workflow stages
  (`eval` / `finalize` / `export+apply` / `full`) and supports:
  - `VIBE_BENCH_SCENARIOS=all|eval|finalize|export_apply|full` (comma-separated)
  - `VIBE_BENCH_CHAIN=<N>`
  - `VIBE_BENCH_WARMUP=<N>` / `VIBE_BENCH_RUNS=<N>`
  - `VIBE_BENCH_EXPORT_JSON=<path>` for hyperfine JSON export
- `just run-wasm-js-string examples/string_basic.vibe` compiles with `--wasm-js-string`
  and runs the result using a JS engine (Node/WebAssembly builtins).

## WASM codegen (prototype)

- `compile_module_wasm(db, path)` emits a minimal wasm-gc compatible module (MVP bytecode).
- `compile_module_wasm_js_string(db, path)` emits a module that uses wasm js-string builtins.
- Supported: `let`, expression statements, block expressions `{ ... }`, `if { ... } else { ... }`, `match ... { ... }`, `Int`/`String`/`Bool`, tuple/record literals, `path(...)` (import), `sh(...)` (import; requires matching effect signature), `+/-/==/<` on `Int` (`==` is syntax sugar lowering to `eq`), `not/and/or` on `Bool`, `record_set(record { ... }, "field", value)` (GC fixtures only).
- Not supported: `import`, qualified calls, or external symbols. Tuple/record patterns are supported, but nested tuple/record patterns are not.
- Exports: `run` (i32) and `memory`. Import: `vibe.sh` when `sh(...)` is used.
- `--wasm-js-string` imports:
  - `wasm:js-string.length/charCodeAt/substring/concat/equals` (as needed).
  - `string_constants.<literal>` globals for string literals.
- `--wasm-js-string` currently treats `String` values as externref, so only string builtins are supported; storing strings inside heap objects (tuple/record/array/map) and returning a top-level string value are not yet supported in this backend.
- ABI note:
  - Heap objects are stored as `[u32 type][u32 len][payload...]` at 4-byte aligned offsets.
  - `type`: `1 = String`, `2 = Path`, `3 = Tuple`, `4 = Record`.
  - `len`: for `String/Path` is byte length, for `Tuple` is arity, for `Record` is field count.
  - `Tuple` payload: `len` tagged values (`u32` each).
  - `Record` payload: `len` pairs of `(u32 name_ptr, u32 value)`; `name_ptr` is an **untagged** pointer to an interned string object. Fields are stored sorted by name.
  - Tagged values use the low 2 bits: `00` = `Int` (fixnum), `01` = `Obj`, `11` = `Bool` (`10` unused).
  - `Int` is encoded as `value << 2` (tag bits `00`).
  - `Bool` is encoded as `(0|1) << 2` with tag bits `11`.
  - `vibe.path` returns a **tagged pointer** (`ptr | 1`).
  - String literals are emitted as **tagged pointers** (`ptr | 1`).
  - Callers must clear tag bits (`ptr & ~3`) before reading object headers.

### WASM GC fixture backend

`compile_module_wasm_gc(db, path)` emits minimal wasm-gc opcodes for fixture checks. This backend is intentionally tiny and only supports:
- `record { ... }` literals → `struct.new`
- `match record { ... } { record { a: x, ... } => x, _ => ... }` → `struct.get`
- `record_set(record { ... }, "field", value)` → `struct.set`

### WASM backend gaps (for shell usage)

- No persistent evaluator API (only a single `run` export; no shell-session eval API).
- No `import` statements; no qualified names or qualified calls.
- Builtins are limited to fixed-arity core ops (`+/-/==/<` on `Int`,
  `not/and/or` on `Bool`, plus `path/sh`; internally lowered to
  `add/sub/eq/lt/not/and/or/path/sh`).
- `sh` / `path` depend on host imports (`vibe.sh`, `vibe.path`).
- No user-defined functions, modules, or recursion in wasm backend yet.

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

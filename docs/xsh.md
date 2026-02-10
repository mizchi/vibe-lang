# xsh language specification

This document captures the current xsh design: a Rust/MoonBit-like, statically
typed, pure functional language with explicit effects, built for WASM/wasip3.

## Status and authority

- `docs/xsh.md` is the normative spec for implemented behavior.
- Items explicitly marked as "future", "proposal", or "draft" are non-normative.
- Design explorations live in separate documents:
  - `docs/module_design.md`
  - `docs/module_system.md`
  - `docs/async_design.md`

## Goals

- POSIX sh superset with a clear syntactic split.
- Pure by default; effects are explicit and checked in two layers:
  effect-set compatibility and effect-boundary (`do`) rules.
- Content-addressed functions (Git blob compatible) with Unison-style aliases.
- Incremental pipeline: CST -> AST -> monomorphized AST -> canonical S-expression -> hash.

## Syntax dispatch

Parser dispatch is explicit:
- parser-consuming CLI commands accept `--syntax xsh|posix`.
- default is `--syntax xsh`.
- `--syntax posix` is a preview mode for runtime-eval commands
  (`run`, `repl`, `repl-stdin`, `repl-wasi`, `bench`).
- static/compile-oriented commands (`check`, `test`, `compile`, `hash`, `save`,
  `fetch`, `update-lock`, `bench-file`, `wasm-repl-stdin`) remain xsh-only.
- Runtime API preview:
  `Runtime::eval_script_with_mode(script, PosixMode)` supports xshell-style
  command-head desugaring (`ls` -> `sh_lines("ls")`).
- In `--syntax posix`, each unresolved bare identifier command-head rewrite
  emits a runtime note (`note: posix-mode command-head desugar: ...`) so
  migration behavior is explicit in `run`/`repl` output.

Reserved leading keyword detection (`let`, `fn`, `type`, `effect`, `import`,
`test`, `try`) exists as helper logic only and does not switch parser modes.

## Effects

Effects are explicit in function signatures and validated by two independent
checks.

```
let run = fn () -> Unit with {Stdout} {
  do {
    sh("ls")
  }
}
```

Rules:
- Effect-set requirement:
  a function's declared effects must be a superset of the effects used inside.
  (`with { ... }` is the capability contract.)
- Effect-boundary requirement:
  some operations require an "effect-allowed" context (`do` boundary).
- `with {}` is optional; omission means pure.
- Capability mapping is 1:1 with the runtime `CapabilitySet`.
- Current builtin mapping:
  - `sh(...)` requires `{Stdout}`
  - `sh_lines(...)` requires `{Stdout}`
  - `stdout_write_char(...)` requires `{Stdout}`
  - `stdout_write_stream(...)` requires `{Stdout}`
  - `stdin_read_char()` requires `{Stdin}`
  - `stdin_read_stream(...)` requires `{Stdin}`
  - `sleep(...)` requires `{Async}`
- Runtime gate (current CLI behavior):
  - `sleep(...)`, `await`, `yield` execution is disabled by default.
  - enable with `--unstable-async` (`xsh run/test/repl/bench ...`).
  - `threads_probe_wat()` execution is disabled by default.
  - `threads_runtime_hints()` execution is disabled by default.
  - enable with `--unstable-threads`.

### Effect-set vs do-boundary (current implementation)

`effect-set` checks and `do` checks are independent.

1. Effect-set check:
   - Calls to functions with effects, `raise`, `await`, and `yield` are checked
     against the current effect scope.
   - `try { ... } catch { ... }` extends only the `try` branch scope with
     `{Error}`.
2. Do-boundary check:
   - Direct effectful builtins (`sh`, stdio, `sleep`) and mutable builder APIs
     (`array_builder*`, `map_builder*`) require an effect-allowed context.
   - Effect-allowed context is enabled inside `do { ... }`, and also inside
     function bodies that already declare non-empty effects.

Examples:

```xsh
// ok: declared effect allows direct builtin call
let run = () -> Unit with {Stdout} { sh("ls") }

// error: do alone does not add missing effect declaration
let run = () -> Unit { do { sh("ls") } }

// error: do alone does not satisfy called function's effect-set requirement
let f = (x: Int) -> Int with {Error} { x }
let g = (y: Int) -> Int { do { f(y) } }

// ok: effect-set is declared; do is not required for this call shape
let f = (x: Int) -> Int with {Error} { x }
let g = (y: Int) -> Int with {Error} { f(y) }
```

Error handling:
- Calling a function with `{Error}` from a non-`{Error}` function requires
  `try { ... } catch { ... }`.
- `try` handles `Error` locally and does not require the caller to declare
  `{Error}`.
- `raise` accepts values that satisfy the `Error` trait.
- `String` is a built-in `Error`, and user code can define new error types with
  `suberror`.

`suberror` declarations:
- `suberror MyError(String)` is shorthand for an enum-like error type with a
  single constructor `MyError(String)`.
- `suberror AppError { Io(String); Parse(Int); }` uses enum-style constructors.
- `suberror` auto-registers `impl Error for <Type>`.

```xsh
suberror AppError {
  Io(String);
  Parse(Int);
}

let fail = () -> Unit with {Error} {
  raise Io("io")
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
- `try { ... } catch { ... }` can localize `{Error}` even inside generic wrappers.
- Trait bounds and effect checks are independent constraints; either can fail
  first depending on the call shape.

Examples:

```xsh
// error: wrapper body calls effect-polymorphic callback without declaring {e}
let apply = [T](f: (x: T) -> T with {e}, x: T) -> T { f(x) }

// ok: Error is localized by try/catch in generic wrapper
let apply_safe = [T](f: (x: T) -> T with {Error}, x: T) -> T {
  try { f(x) } catch { x }
}
```

## let mut and async boundaries

`let mut` is allowed only for local, block-scoped re-assignment.

Constraints:
- `let mut` variables cannot be captured by async closures.
- `let mut` variables cannot remain live across `await`/`spawn`.
- Snapshotting is required to pass data into async closures.

This is equivalent to "borrow across await" being forbidden.

Discard binding (`let _ = ...`):
- `_` is a wildcard discard binding and is not stored in value/type namespaces.
- `let _ = ...` can be used multiple times in the same scope.
- `let rec _ = ...` is rejected.

## Labeled arguments (MoonBit-style)

Definition:
```
fn foo(x~: Int, y?: Int = 2) -> Int { ... }
```

Call:
```
foo(x=1, y=2)
```

Shell view (conceptual):
```
foo -x=1 -y=2
```

Rules:
- `x~` is required (must be supplied by label).
- `y?` is optional: without a default it is `Int?`, with a default it is `Int`.
- Call arguments are reordered to match the parameter order during lowering.
- Missing optional args are expanded to defaults in IR.

## Builtins (current)

Array/Map:
- `array_length(array)` -> `Int`
- `array_get(array, index)` -> element
- `map_get(map, key)` -> element (key is `String`)

String (aligned with wasm js-string builtins when using `--wasm-js-string`):
- `string_length(string)` -> `Int`
- `string_char_code_at(string, index)` -> `Int`
- `string_from_char_code(code)` -> `String`
- `string_substring(string, start, end)` -> `String`
- `string_concat(left, right)` -> `String`
- `string_equals(left, right)` -> `Bool`

StdIO (wasi stream primitives for wasm/component-friendly interop):
- `sh_lines(cmd)` -> `Array[String]` with `{Stdout}`.
  Current interpreter executes a builtin command subset (`ls`, `cat`, `echo`)
  and returns output lines while also recording `ShellExec(cmd)` effect.
- `stdout_write_char(code)` -> `Unit` with `{Stdout}`
- `stdout_write_stream(text)` -> `Unit` with `{Stdout}` (chunk write)
- `stdin_read_char()` -> `Int` with `{Stdin}` (`-1` = EOF)
- `stdin_read_stream(max-bytes)` -> `String` with `{Stdin}` (`""` = EOF/error)
- component WIT/wasm import mapping:
  - `stdout_write_char` -> `wasi:cli/stdout@0.2.0#get-stdout` + `wasi:io/streams@0.2.0#[method]output-stream.blocking-write-and-flush`
  - `stdout_write_stream` -> same as `stdout_write_char` (single host call for whole chunk)
  - `stdin_read_char` -> `wasi:cli/stdin@0.2.0#get-stdin` + `wasi:io/streams@0.2.0#[method]input-stream.blocking-read`
  - `stdin_read_stream` -> same as `stdin_read_char` (cabi read-buffer -> xsh string)

Threads (experimental, runtime-gated by `--unstable-threads`):
- `threads_probe_wat()` -> `String`
- `threads_runtime_hints()` -> `{ wasm_flags: Array[String], wasi_flags: Array[String], wasm_env: String, wasi_env: String }`
- `threads_channel_new(capacity: Int)` -> `Int` (channel id)
- `threads_send(channel_id: Int, message: String)` -> `Bool`
- `threads_recv(channel_id: Int)` -> `String` (`""` when empty)
- `threads_spawn(name: String, channel_id: Int)` -> `Int` (task id)
- `threads_wait(task_id: Int)` -> `Int` (current minimal runtime returns `0`)
- `xsh/std/threads.xsh` は test-safe な pure contract 層を分離:
  - `task_spec`, `channel_spec`, `actor_spec`, `deployment_plan`, `recommended_*`
  - これらは通常 `xsh test` で実行可能
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
- These aliases are parser-level synonyms and normalize to canonical xsh types.
- `i32`/`f32`/`f64` are reserved type names and cannot be redefined with `type`, `enum`, or `struct`.
- Canonical type names (`Int`/`Float`/`Double`) remain the public spec baseline.

Core std module:
- `xsh/std/wasm/types.xsh` provides an official wasm-facing entrypoint (`I32`/`F32`/`F64` aliases and helpers).
- `xsh/std/wasm/opcodes.xsh` provides opcode-style low-level APIs (`i32_add`, `i32_div_s`, `f64_promote_f32`, ...).
  - Naming rule: wasm `i32.add` is exposed as xsh `i32_add` (dot replaced with `_`).

## Names, hashes, versions, and symbols (Unison-style)

xsh uses a layered reference model:

- `HashRef`: immutable content address of canonical S-expression IR (source of truth).
- `VersionRef`: mutable namespace/branch pointer to hashes.
- `SymbolRef`: mutable human-readable name pointer to hashes.

Execution and dependency identity are hash-based. `VersionRef`/`SymbolRef` are
authoring/navigation aliases that normalize to hash before evaluation.

### Canonical reference schema

Reference forms accepted by parser and importer:

- `PathRef`: `./foo.xsh`, `../foo.xsh`, `/abs/foo.xsh`, `"./foo.xsh"`
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
module_ref = "ko-doha/xsh/" + hash
```

- Content hash input is canonical S-expression IR produced by compiler pipeline.
- Human-facing metadata (path aliases, formatting trivia, spans) is excluded.
- There is no `sha256` content hash path in the current compiler.

Separate internal hash:
- `Module::structural_hash() -> Int` is used only for incremental query equality
  (`HashedModule`) and backdate optimization; it is not a persistent content ID.

## Imports and exports

### Surface syntax (current)

Imports are named imports only:

```xsh
import { foo, bar as b } from ./path/to/mod.xsh
import { type IntPair, trait Show, foo, bar } from ./path/to/mod.xsh
import { foo } from "./path/to/mod.xsh"
import { foo } from #abc12345
import { foo } from version@main
import { foo } from symbol@std/math
```

Per-item import kind:
- `foo` / `foo as alias`: value import (default)
- `type T`: type import (type alias / enum namespace)
- `trait Eq`: trait import
- `type Int` can be used as namespace activation for `Int::...` exports.
- If a non-default qualifier (`type` / `trait`) does not match the exported
  symbol category, compiler emits an `import` diagnostic.

Parser compatibility:
- `version:<name>` / `symbol:<name>` are accepted, but `@` form is canonical.

Exports are explicit:

```
export let add = (x: Int, y: Int) -> Int { x + y }
export enum Color { Red; Green; Blue }
export type IntPair = (Int, Int)
export { add, Color, IntPair }
export { foo } from "./other.xsh"
```

Rules:
- No implicit "export all".
- Non-exported top-level names are module-private.
- `import "foo.xsh"` (bare import) and default import forms are not part of the
  current spec.

### Type-member imports (proposal)

Namespace-explicit style (ESM/Python-like) is adopted for type-attached
functions.

Proposed forms:

```xsh
import { type Int } from "./xsh/std/int.xsh"             // also imports Int::*
import { Int } from "./xsh/std/int.xsh"                  // backward-compatible
import { Int::to_string } from "./xsh/std/int.xsh"       // single member
import { Int::to_string as int_to_string } from "./xsh/std/int.xsh"
```

Rules:
- `import { Int } from <module-ref>` activates namespace binding `Int:: ->
  <module-ref>` in the current module scope.
- Activated `Int::` resolves `Int::*` only from the bound `<module-ref>`.
  Example: if target is `std/int`, only exported `Int::...` symbols in
  `std/int` become resolution candidates.
- `import { Int::name } from <module-ref>` imports only that member from that
  `<module-ref>`.
- Overwrite is forbidden:
  if an already-bound namespace or symbol key (`Int::` or `Int::name`) is
  bound to a different target module, it is a compile error.
- Re-importing an identical binding for the same namespace key is idempotent.

### Module refs and normalization

`import ... from <module-ref>` accepts:
- `PathRef`: local/module path literal.
- `HashRef`: content hash literal (`#...`).
- `VersionRef`: namespace pointer.
- `SymbolRef`: symbol pointer.

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
  - `index.xdb` is checked first; when it includes lock payload
    (`path`/`version`/`symbol`/`module`/`annotation` or `lock` object),
    that payload is used as lock source.
  - If `index.xdb` has no lock payload, loader falls back to `index.lock`.
  - Legacy compatibility: if `index.lock` is absent and `xsh.lock` exists in the
    same directory, loader reads `xsh.lock`.
- Shape:
  - `path`: `{ "<path-key>": "<hash>" }`
  - `version`: `{ "<name>": "<hash>" }`
  - `symbol`: `{ "<name>": "<hash>" }`
  - `module`: `{ "<normalized-path>#<export-name>": "<normalized-export-hash>" }`
  - `annotation`: `{ "<key>": "<note-text>" }`
- `path` keys are written as lock-dir-relative paths (`./foo.xsh`) and resolved
  to normalized absolute paths when loading (absolute keys are also accepted).
- Root guard:
  - index root is the nearest ancestor directory containing `index.xsh`
    (fallback: entry directory).
  - `index.xsh` must export version:
    `export let version = "0.1.0"` (simple semver `x.y.z`).
  - Path imports are rejected when resolved path escapes index root.
  - `index.xsh` may define `export let module = record { <ns>: "<dir>" }` to map
    namespace imports (for example `std/...`) under root.
  - Default namespace mapping includes `std -> ./xsh/std`.
- CLI:
  - `xsh apply <entry>` resolves recursive path imports, updates `index.lock`,
    injects prelude refs, and updates `index.xdb.graph_head`.
    It also stores the graph snapshot object under `.xsh/objects/<graph-head>`.
  - `xsh fetch <entry>` (or `xsh update-lock <entry>`) resolves recursive
    path imports and updates `index.lock`.
  - `fetch/update-lock` also injects prelude refs:
    - `version.prelude = <normalized-prelude-hash>`
    - `symbol."std/prelude" = <normalized-prelude-hash>`
    and stores the normalized prelude module object under `.xsh/objects/`.
  - `xsh check <entry...>` runs the same resolution/apply pipeline as `xsh apply`
    before diagnostics.
  - `xsh run/compile/test` require lock entries for path imports;
    missing/mismatch emits import diagnostics and fails compile.

## Trait and impl rules (current)

```xsh
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
- External impls are allowed only for traits imported as `open`.
- `impl` type parameters must be unique.
- Bounds in `impl [T: A + B]` are deduplicated and each bound must be a known
  trait.
- Overlapping impls for the same trait are rejected.
- Supertrait satisfaction is transitive (`impl Ord for T` also satisfies `Eq`
  when `trait Ord: Eq`).
- Trait imports are explicit (`import { Eq } from ...`), and only exported
  traits can be imported across modules.
- Import renaming preserves canonical source identity for supertrait checks
  (`Eq as MyEq` keeps relation to canonical `Eq`).

## Struct and enum details (current)

```xsh
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

## Placeholder lambda shorthand (current)

```xsh
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

## Method-call and index desugaring (current)

```xsh
value.method(a, b) // => method(value, a, b)
value.prop         // => prop(value)
t.0                // tuple index
arr[i]             // => __index(arr, i)
```

Rules:
- Postfix chains are parsed left-to-right.
- `expr.method(...)` inserts `expr` as the first positional argument.
- `expr.prop` desugars to a one-argument call (`prop(expr)`).
- `.0`, `.1`, ... are parsed as tuple index expressions.
- `expr[index]` desugars to `__index(expr, index)`.
- Type checking resolves calls first as normal functions/ctors/builtins.
  Field-access typing (`prop(expr)`) is fallback behavior.
- Field-access fallback currently supports record and struct fields, requiring
  exactly one positional argument.

### Type-qualified method symbols (proposal)

To avoid global-name collisions such as multiple `to_string` definitions, xsh
plans to add type-qualified method symbols.

Proposed declaration syntax:

```xsh
let Int::to_string = (x: Int) -> String { "int" }
let String::to_string = (x: String) -> String { x }
export let Option::unwrap_or = [T](opt: Option[T], fallback: T) -> T {
  match opt {
    Some(v) => v
    None => fallback
  }
}
```

Design notes:
- Canonical separator is `::` (`Type::method`).
- `Type/method` is not adopted because `/` is already used by module-qualified
  symbol paths and hash/module refs.
- `Type::method` is treated as one function symbol key; this is not trait
  syntax.
- Receiver genericity is represented by root type name (for example
  `Option::unwrap_or`), while type parameters remain in function signature.

Evaluation policy:
- Simple global desugar (`recv.method(...) -> method(recv, ...)`) is not used
  for extension methods.
- `Type::method(recv, ...)` is the canonical call form.
- `recv.method(...)` is allowed as sugar only when it resolves to an imported
  `Type::method` member.

Proposed resolution order for `recv.method(args...)`:
1. Infer receiver type `T`.
2. Find active namespace binding `T:: -> <module-ref>`.
3. Resolve `T::method` from that `<module-ref>` exports.
4. If exactly one match exists, lower to `T::method(recv, ...)`.
5. If zero matches, emit `method not found`.
6. If multiple matches exist, emit ambiguity error.
7. Do not fall back to global `method(recv, ...)`.

Import/export behavior (proposal):
- `Type::method` participates in normal named import/export as a symbol.
- Example:

```xsh
export { Int::to_string, String::to_string }
import { Int::to_string as int_to_string } from "./std/stringify.xsh"
```

### Prelude and `--nostd` (proposal)

- Default mode preloads std namespaces/members through prelude imports.
  This includes type-member namespaces used by method sugar.
- `--nostd` disables all implicit prelude imports.
- In `--nostd`, all type/member namespaces must be imported explicitly.

## xshell command pipeline (PosixMode preview)

```xsh
let run = () -> Array[String] with {Stdout} {
  do {
    ls |> where((line: String) -> Bool { string_contains(line, "xsh") })
  }
}
```

Rules:
- In `PosixMode`, unresolved bare identifier expressions are desugared to
  `sh_lines("<ident>")`.
- Bound names (`let`, function params, pattern bindings, imported names) are
  preserved and not desugared as commands.
- `where(xs, pred)` is available in prelude for `Array[String]` stream-style
  filtering.

## while / break / continue / await / yield (current)

```xsh
while cond {
  step()
}

break
continue
await task()
yield value
```

Rules:
- `while` condition must be `Bool`.
- `while` body is type-checked, and the expression result type is always `Unit`.
- `break` and `continue` are valid only inside `while` loop bodies.
- Using `break`/`continue` outside `while` is a type error.
- Runtime loop control uses `break` to exit the nearest loop and `continue` to
  start the next iteration.
- `await expr` requires `{Async}` and returns the inner expression type.
- `yield expr` requires `{Async}` and returns `Unit`.
- Runtime execution for `await` / `yield` is gated by `--unstable-async`
  (disabled by default in CLI entrypoints).

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
- `Runtime::eval_script_with_mode(script, PosixMode)` enables preview xshell
  command-head desugaring.
CLI:
- `moon run --target native src/cmd/xsh -- run <file>` executes a script (ignores `test {}`).
- `moon run --target native src/cmd/xsh -- eval [--db tmp1.db] [--include index.xdb] <expr...>` evaluates one expression/script; with `--db`, appends evaluated source for incremental sessions, and `--export <file>` writes accumulated source.
  - `--include` accepts path forms and alias forms:
    - `--include=bit:<path>`: explicit alias to path-backed source.
    - `--include=xsh/std@0.1.0.xdb`: named alias resolved from `XSH_LIB_DIR` (fallback: `$HOME/.xsh/lib`).
  - `.xdb` alias file may store `hash:<sha1>` (or JSON `{ "hash": "<sha1>" }`); `eval` resolves the module source from local object stores.
- `moon run --target native src/cmd/xsh -- test <file...>` runs test blocks and prints a report.
- `moon run --target native src/cmd/xsh -- compile [--wasm | --wasm-js-string] [-o out] <file>` emits IR (default) or wasm bytes.
- `moon run --target wasm src/cmd/xsh_compile_wasi -- [compile] [--wasm|--wasm-mvp|--wasm-js-string|--wasm-gc|--component|--wit|--wit-component] [-o out] <file>` runs compile pipeline from wasm target as well.
  - `xsh_compile_wasi` only: `--wasm` prefers `wasm-gc`; use `--wasm-mvp` for core wasm backend (broader language coverage).
- Parser-consuming commands support `--syntax xsh|posix` (default `xsh`);
  `posix` is preview-enabled for `run/eval/repl/repl-stdin/repl-wasi/bench` and is
  rejected on static/compile-oriented commands.
- `moon run --target native src/cmd/xsh -- repl` launches the TUI interactive shell (completion + layout, history).
- `moon run --target native src/cmd/xsh -- repl-stdin [--no-prompt]` reads lines from stdin and evaluates them.
- `moon run --target native src/cmd/xsh -- repl-wasi [--no-prompt] [--tty|--no-tty]` runs line REPL with wasi-style prompt/tty options.
- `moon build --target wasm src/cmd/xsh_wasi` builds a wasm line REPL wired to preview2 imports (`wasi:cli/stdin|stdout`, `wasi:io/streams`).
- `moon build --target wasm src/cmd/xsh_compile_wasi` builds wasm compiler CLI (filesystem side is abstracted via `src/io.FileSystemAdapter`).
- `just component-run script.xsh` builds a stdio-capable component and runs it via wasmtime (`--invoke 'run()'`).
- `just component-run-moonix script.xsh` builds the same component and runs it via moonix.
- `just bootstrap-moonix [src]` tries to produce `moonix` binary from a local moonix checkout.
- TUI completion sources: builtins + PATH commands + history.
- `just install` installs a native binary to `~/.local/bin/xsh` (override with `XSH_PREFIX`).
- Imports are loaded recursively (imports of imports) for hashing and import-rename resolution.
- Import cycle reporting is implemented for path-based import graphs
  (diagnostic stage: `import`, message prefix: `import cycle:`).

Fixtures:
- `fixtures/*.xsh` include a `__DATA__` JSON block and are executed by `moon test`.
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
- `just bench-wasmtime` builds `cmd/xsh`, compiles `bench/bench_simple.xsh` to wasm,
  then benchmarks `wasmtime run --invoke run`.
- `just bench-compare` compares interpreter (`cmd/xsh run`) vs `wasmtime run`.
- `xsh bench --n 20000 --warmup 1000 --expr "add(1,2)"` measures per-command latency
  after startup inside a single process.
- `xsh bench --case sum=add(1,2) --case "1 == 1"` runs multiple named
  expression benchmarks in one invocation.
- `xsh bench --cases bench/cases.txt` loads benchmark cases from file
  (one case per line, `name=expr` or plain `expr`; blank/comment lines are ignored).
- `xsh index ref push <scope> <index-file>` / `pull <scope> <out-file>` maps advanced graph snapshots to git/bit refs under
  `refs/bit/index/<scope>/graph/head`.
- `xsh index ref push-delta <scope> <delta-file>` / `pull-delta <scope> <out-file>` maps advanced graph deltas to
  `refs/bit/index/<scope>/graph/wal_head`.
- `just bench-cmd-latency` compares per-command latency between interpreter and a
  resident wasmtime instance.
- `just run-wasm-js-string examples/string_basic.xsh` compiles with `--wasm-js-string`
  and runs the result using a JS engine (Node/WebAssembly builtins).

## WASM codegen (prototype)

- `compile_module_wasm(db, path)` emits a minimal wasm-gc compatible module (MVP bytecode).
- `compile_module_wasm_js_string(db, path)` emits a module that uses wasm js-string builtins.
- Supported: `let`, expression statements, block expressions `{ ... }`, `do { ... }`, `if { ... } else { ... }`, `match ... { ... }`, `Int`/`String`/`Bool`, tuple/record literals, `path(...)` (import), `sh(...)` (import; only inside `do`), `+/-/==/<` on `Int` (`==` is syntax sugar lowering to `eq`), `not/and/or` on `Bool`, `record_set(record { ... }, "field", value)` (GC fixtures only).
- Not supported: `import`, qualified calls, or external symbols. Tuple/record patterns are supported, but nested tuple/record patterns are not.
- Exports: `run` (i32) and `memory`. Import: `xsh.sh` when `sh(...)` is used.
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
  - `xsh.path` returns a **tagged pointer** (`ptr | 1`).
  - String literals are emitted as **tagged pointers** (`ptr | 1`).
  - Callers must clear tag bits (`ptr & ~3`) before reading object headers.

### WASM GC fixture backend

`compile_module_wasm_gc(db, path)` emits minimal wasm-gc opcodes for fixture checks. This backend is intentionally tiny and only supports:
- `record { ... }` literals → `struct.new`
- `match record { ... } { record { a: x, ... } => x, _ => ... }` → `struct.get`
- `record_set(record { ... }, "field", value)` → `struct.set`

### WASM backend gaps (for shell usage)

- No persistent evaluator API (only a single `run` export; no REPL-style eval).
- No `import` statements; no qualified names or qualified calls.
- Builtins are limited to fixed-arity core ops (`+/-/==/<` on `Int`,
  `not/and/or` on `Bool`, plus `path/sh`; internally lowered to
  `add/sub/eq/lt/not/and/or/path/sh`).
- `sh` / `path` depend on host imports (`xsh.sh`, `xsh.path`).
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
(do (block (stmts ...)))
(tuple <expr> ...)
(tuple-index <expr> 0)
(record (field "k" <expr>) ...)
(struct-lit "Type" (field "k" <expr>) ...)
(array <expr> ...)
(map (field "k" <expr>) ...)
(try (block (stmts ...)) (block (stmts ...)))
(fn (params (param "x" pos <type>) ...) (ret <type>|_) (effects <eff> ...) (block (stmts ...)))
(while <expr> (block (stmts ...)))
(raise <expr>)
(await <expr>)
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
Int | Float | Double | Bool | String | @core.Path | Unit | Never
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

## Compile + run (prototype)

- `compile_module(db, path)`:
  - parse + type check
  - desugar + monomorphize AST
  - rewrite imports to hash refs
  - serialize canonical S-expression IR
  - compute Git blob `sha1` and module ref
- `Runtime::run_compiled(compiled)`:
  - executes via interpreter (WASM backend is a prototype codegen)

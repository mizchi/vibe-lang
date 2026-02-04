# xsh specification (draft)

This document captures the current xsh design: a Rust/MoonBit-like, statically
typed, pure functional language with explicit effects, built for WASM/wasip3.

## Goals

- POSIX sh superset with a clear syntactic split.
- Pure by default; effects are explicit and only allowed in `do { ... }`.
- Content-addressed functions (Git blob compatible) with Unison-style aliases.
- Incremental pipeline: CST -> AST -> typed IR -> hash + dependency DAG.

## Syntax dispatch

If the first non-trivia token is one of the xsh keywords, treat the script as xsh.
Otherwise, fall back to the POSIX sh parser.

Reserved leading keywords: `let`, `fn`, `type`, `effect`, `alias`, `import`, `flake`, `test`, `try`.

## Effects

Effects are explicit in function signatures and only allowed inside `do { ... }`
blocks.

```
let run = fn () -> Unit with {Stdout} {
  do {
    sh("ls")
  }
}
```

Rules:
- Effectful calls outside `do` are type errors.
- A function's declared effects must be a superset of the effects used inside.
- `with {}` is optional; omission means pure.
- Capability mapping is 1:1 with the runtime `CapabilitySet`.
- Current builtin mapping: `sh(...)` requires `{Stdout}` (in addition to `do`).

Error handling:
- Calling a function with `{Error}` from a non-`{Error}` function requires
  `try { ... } catch { ... }`.
- `try` handles `Error` locally and does not require the caller to declare
  `{Error}`.

## let mut and async boundaries

`let mut` is allowed only for local, block-scoped re-assignment.

Constraints:
- `let mut` variables cannot be captured by async closures.
- `let mut` variables cannot remain live across `await`/`spawn`.
- Snapshotting is required to pass data into async closures.

This is equivalent to "borrow across await" being forbidden.

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
- `string_substring(string, start, end)` -> `String`
- `string_concat(left, right)` -> `String`
- `string_equals(left, right)` -> `Bool`

## Names, hashes, and aliases (Unison-style)

Functions are identified by their content hash (`FnId`), not by names.

- `name#abc` = name with hash suffix prefix (shortest unique allowed).
- `alias foo = bar#abc` registers `foo` as a module alias to that referent.
- `name` without a hash is resolved through alias tables. Ambiguity is an error.

Hash prefix resolution:
- If a prefix uniquely matches a known `FnId`, it resolves.
- 0 or >1 matches is an error.

## Content address (Git blob compatible)

FnId is computed from canonicalized typed IR:

```
sha1("blob " + len + "\0" + ir_bytes)
```

The hash does not include aliases or the human-friendly name.

## Imports

```
import foo.xsh
import "foo.xsh"
```

Import resolution pins to content hash:
- compute `hash = git_blob_hash(source)`
- canonical module ref: `ko-doha/xsh/<hash>`
- the reference is fixed by hash, not by file name

### Module system (draft)

Goals:
- Express Nix-like "fixed input + pure output + reproducibility" via imports.
- Fix dependencies at resolve/build time, not at runtime.
- Keep syntax close to current xsh where possible.

Core ideas:
- `import` is a pure expression that returns a module namespace (record-like).
- Dependency pinning is done via `SourceSpec` + lock file.
  - `SourceSpec` is an abstract structure; concrete literal syntax is TBD.
  - Missing lock entry is a compile error.
  - A separate command (e.g. `xsh fetch`) generates/updates the lock.
- After resolution, modules are referenced by content hash (aligned with FnId).
  - Internally, symbols can be tracked as `name#hash` while keeping a human name.

Export model (choose one):
A. Explicit `export` (recommended)
```
let add = fn (x: Int, y: Int) -> Int { x + y }
let sub = fn (x: Int, y: Int) -> Int { x - y }
export { add, sub }
```
B. Implicit export (all top-level lets/types/enums)
- Simple, but leaks more than intended.
C. Convention: `exports` record only
```
let exports = record { add, sub }
```
- No new syntax; `import` reads only `exports`.

Import syntax extensions (minimal):
```
import "path/to/mod.xsh" as mod
import { add, sub } from "path/to/mod.xsh"
import mod from "path/to/mod.xsh"
```

Purity and effects:
- Import resolution and downloads happen at compile time.
- Runtime uses only locked content, so `import` stays pure and effect-free.

Example (future):
```
import "git:github:NixOS/nixpkgs@rev#hash//pkgs.xsh" as pkgs

let dev_shell = pkgs.mk_shell {
  packages = [ pkgs.wasm, pkgs.nodejs ]
}

export { dev_shell }
```

Open questions:
- Concrete `SourceSpec` literal syntax (string vs record vs dedicated literal).
- Export syntax (`export` keyword vs implicit vs convention).
- Lock file format and location (e.g. `xsh.lock`).
- Error design for missing/invalid imports.

Next steps:
1. Decide export model.
2. Decide minimal import syntax additions.
3. Decide `SourceSpec` syntax.
4. Decide lock workflow (generate/update/verify).

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
CLI:
- `moon run --target native src/xsh_cli -- run <file>` executes a script (ignores `test {}`).
- `moon run --target native src/xsh_cli -- test <file...>` runs test blocks and prints a report.
- `moon run --target native src/xsh_cli -- compile [--wasm | --wasm-js-string] [-o out] <file>` emits IR (default) or wasm bytes.
- `moon run --target native src/xsh_cli -- repl` launches the TUI interactive shell (completion + layout, history).
- `moon run --target native src/xsh_cli -- repl-stdin [--no-prompt]` reads lines from stdin and evaluates them.
- TUI completion sources: builtins + PATH commands + history.
- `just install` installs a native binary to `~/.local/bin/xsh` (override with `XSH_PREFIX`).
- Imports are loaded recursively (imports of imports) for hashing/alias resolution.
- Import cycle reporting is TODO.

Fixtures:
- `fixtures/*.xsh` include a `__DATA__` JSON block and are executed by `moon test`.
- Fields:
  - `last`: expected `Value::to_string()` (exact match).
  - `effects`: expected `Effect::to_string()` list (exact match).
  - `error_contains` / `compile_error`: substring match for failures.
  - `TODO`: test must fail; passing means the TODO should be removed.
  - `skip`: skip the fixture.

Bench:
- `just bench-wasmtime` builds `xsh_cli`, compiles `bench/bench_simple.xsh` to wasm,
  then benchmarks `wasmtime run --invoke run`.
- `just bench-compare` compares interpreter (`xsh_cli run`) vs `wasmtime run`.
- `xsh bench --n 20000 --warmup 1000 --expr "add(1,2)"` measures per-command latency
  after startup inside a single process.
- `just bench-cmd-latency` compares per-command latency between interpreter and a
  resident wasmtime instance.
- `just run-wasm-js-string examples/string_basic.xsh` compiles with `--wasm-js-string`
  and runs the result using a JS engine (Node/WebAssembly builtins).

## WASM codegen (prototype)

- `compile_module_wasm(db, path)` emits a minimal wasm-gc compatible module (MVP bytecode).
- `compile_module_wasm_js_string(db, path)` emits a module that uses wasm js-string builtins.
- Supported: `let`, expression statements, block expressions `{ ... }`, `do { ... }`, `if { ... } else { ... }`, `match ... { ... }`, `Int`/`String`/`Bool`, tuple/record literals, `path(...)` (import), `sh(...)` (import; only inside `do`), `add/sub/eq/lt` on `Int`, `not/and/or` on `Bool`, `record_set(record { ... }, "field", value)` (GC fixtures only).
- Not supported: `import`, `alias`, qualified calls, or external symbols. Tuple/record patterns are supported, but nested tuple/record patterns are not.
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
- No `import` / `alias` statements; no qualified names or qualified calls.
- Builtins are limited to `add/sub/eq/lt/not/and/or/path/sh` with fixed arity.
- `sh` / `path` depend on host imports (`xsh.sh`, `xsh.path`).
- No user-defined functions, modules, or recursion in wasm backend yet.

## Pure result cache (Unison-style)

Pure function results are cached by content-derived keys.

- Cache entries are **not** included in module content hashes.
- Cache snapshots live in a separate file and are loaded externally.
- Snapshot format is line-based: `<hash>\\t<encoded-value>`.

## Self recursion only

Only self recursion is allowed:
- `self` is a special IR node for self calls.
- Dependencies exclude `self`.
- Any SCC of size >1 is an error.

## S-expression IR (canonical form)

Top-level:
```
(module
  (defs <def> ...)
  (aliases <alias> ...))
```

Definitions:
```
(def
  (name foo#abc123)       ; human alias (not hashed)
  (id   sha1:deadbeef...) ; content hash
  (params <param> ...)
  (ret <type>)
  (eff <effset>)
  (body <expr>))
```

Params:
```
(param (name x) (label req|opt|plain) (type <type>) (default <expr>)?)
```

Types:
```
(type Int|Bool|String|Path|Unit)
(type (tuple <type>...))
(type (record (field <name> <type>) ...))
(type (fn (params <type>...) (ret <type>) (eff <effset>)))
```

Effect set:
```
(eff (Shell FsWrite ...)) ; empty: (eff ())
```

Expr:
```
(lit (int 1))
(lit (string "abc"))
(lit (path "/a/b"))
(lit unit)

(local 0)
(self)
(global sha1:...)

(call <callee> (args <expr>...))

(let <local> <expr> <expr>)
(letmut <local> <expr> <expr>)
(assign <local> <expr>)

(if <expr> <block> <block>)
(match <expr> (arms (arm <pat> (guard <expr>)? <expr>) ...))

(do <block>)
(async <expr>)
(await <expr>)

(block (stmts ...))
(tuple <expr>...)
(record (field <name> <expr>) ...)

Match pattern (prototype):
- literals: `int`, `bool`, `string`
- wildcard: `_` (required for exhaustiveness)
- bind: `name` (binds scrutinee, counts as exhaustive)
- tuple: `(p1, p2, ...)`
- record: `record { a: p1, b: p2 }`
- guard: `pat if <expr> => <expr>` (guard must be `Bool`)
```

Stmt:
```
(stmt <expr>)
(stmt (let ...))
(stmt (letmut ...))
(stmt (assign ...))
```

Canonicalization rules:
- Local variables are normalized (de Bruijn/SSA).
- Call args are reordered by parameter order.
- Optional args are expanded to defaults.
- Effect sets are sorted.
- `do/async/await` are explicit nodes.

## Dependency DAG

Dependencies are extracted from `global` references in IR:
- `self` is excluded.
- Dependencies are unique + sorted.
- SCC size >1 is an error (self recursion only).

## CST -> AST -> IR

Parsing builds a CST (using `mizchi/cst`), then lowers to AST.
IR is produced from typed AST with canonicalization.

## Compile + run (prototype)

- `compile_module(db, path)`:
  - parse + type check
  - import alias resolution
  - canonical S-expression IR generation
  - Git blob hash (`FnId`-style) + module ref
- `Runtime::run_compiled(compiled)`:
  - executes via interpreter (WASM backend is a prototype codegen)

CST node kinds (minimum set):
- tokens: keywords, literals, identifiers, punctuation, trivia, error
- nodes: `source_file`, `let_stmt`, `fn_def`, `param_list`, `param`,
  `type_def`, `effect_def`, `alias_stmt`, `import_stmt`, `flake_block`, `block`, `expr_stmt`,
  `do_block`, `if_expr`, `match_expr`, `call_expr`, `arg_list`, `name_ref`,
  `literal`, `assign_stmt`, `async_expr`, `await_expr`

Lowering rules:
- `alias` nodes register aliases, not hashed.
- `name#hash` is parsed as `(name, hash_prefix)` then resolved to `FnId`.
- `self` uses special IR node.

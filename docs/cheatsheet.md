# vibe Language Cheat Sheet

WASM-targeting, pure-by-default language with algebraic effects. Compiled via MoonBit toolchain.

## Quick Start

```vibe
// `stdout_write` is a prelude helper, not a builtin — import it (otherwise the
// checker reports `unknown function: String::stdout_write`).
import ./lib/@vibe/prelude/io.vibe { stdout_write }

let main: () -> Unit with { Stdout } = () -> {
  stdout_write("hello world\n")
}
```

```bash
vibe run hello.vibe        # compile & execute
vibe shell                 # interactive shell
vibe test file.vibe        # run tests
vibe check file.vibe       # type check only
vibe build --release app.vibe  # standalone .wasm
```

---

## Values & Types

```vibe
let x: Int = 42                // 62-bit tagged, max 2^61-1
let f: Float = 1.5f            // 32-bit (suffix f)
let d: Double = 3.14           // 64-bit (default decimal)
let s: String = "hello \{x}"   // interpolation with \{expr}
                               // (旧 `\(x)` は 0.3.0 で削除、`\{x}` を使う)
let c: Char = 'A'              // char code (Int alias)
let b: Bool = true
let u: Unit = ()
```

## Variables

```vibe
let x = 42            // immutable
let y = {             // mutable is local/block-scoped
  let mut value = 0
  value += 1
  value
}
```

### Choosing a mutation style

vibe has 5 ways to express mutable state. Pick the simplest one that
covers your scope:

| Want | Use | Notes |
|---|---|---|
| Local counter, accumulator | `let mut x = ...` | block-scoped; cannot escape the function via async/spawn (ADR-0017) |
| Growable buffer (bytes / chars) | `Bytes` / `String` | immutable binding, mutable interior |
| Growable array | `ArrayBuilder` → `Array::from_array_builder` | preferred over `Array::push` on `Array` |
| Mutable cursor in a struct | `struct S { mut field: T }` + `r.field = v` | ADR-0052; same responsibility model as `Array[T]` field |
| Cross-call / handler-mediated state | `effect Mut { ... } + handle ... with Mut` | ADR-0021; tail-resumptive is zero-cost |

Anti-patterns:
- `Array::push(arr, ...)` on a plain `Array` — semantics differ
  per-backend (wasm-gc local-rebinds via best-effort, linear mutates
  in-place); prefer `ArrayBuilder` for any non-trivial accumulation
- `Ref[T]` — historically abandoned (ADR-0017), use the table above

## Functions

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }   // for hello() below

// Top-level named functions: `fn` (#727, ADR-0064). Full annotations
// required (param types + return type); recursion needs no `rec`.
fn add(x: Int, y: Int) -> Int { x + y }
fn fact(n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
fn identity[T](x: T) -> T { x }                // generic
fn show[T: Eq + Ord](x: T) -> T { x }          // trait bounds
fn hello() -> Unit with { Stdout } { stdout_write("hi\n") }
export fn doubled(x: Int) -> Int { x * 2 }
```

`fn` is top-level only — pure parse-time sugar for the `let rec` form below,
so checker/codegen semantics are identical. The optional
`where { requires: .., ensures: .. }` contract clause parses but has no
semantics yet (ADR-0064 Phase E, #731). `vibe fmt`/normalize currently
refuse fn-bearing sources (printer support lands with the fmt migration).

```vibe
// let form: values, computed functions, higher-order returns
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let inc: (Int) -> Int = (x) -> { x + 1 }
let rec fact: (Int) -> Int = (n) -> {     // recursive
  if n < 2 { 1 } else { n * fact(n - 1) }
}
let identity: [T](T) -> T = (x) -> { x }  // generic
let show: [T: Eq + Ord](T) -> T = (x) -> { x } // trait bounds
```

> **Deprecated**: `let f = (x: Int) -> Int { ... }` (inline param types)
> is deprecated. Use `vibe fmt` to auto-convert.

### Labeled arguments

```vibe
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
f(x=10, y=20)
```

### Lambda shorthand

```vibe
Array::map(xs, x -> x * 2)
Array::map(xs, _ * 2)         // placeholder
Array::fold(xs, 0, _ + _)
```

## Operators (precedence: high to low)

| Prec | Operators | Notes |
|------|-----------|-------|
| 1 | `.` `()` `[]` | field, call, index |
| 2 | `-x` `!x` | unary |
| 3 | `*` `/` `%` | |
| 4 | `+` `-` | |
| 5 | `<<` `>>` | >> is arithmetic (sign-extending) |
| 6-8 | `&` `^` `\|` | bitwise AND, XOR, OR |
| 9 | `==` `!=` `<` `<=` `>` `>=` | non-assoc |
| 10 | `\|>` | pipe |
| 11-12 | `&&` `\|\|` | short-circuit (desugar to if) |

Assignment: `=` `+=` `-=` `*=` `/=` `%=` (statement, not expr)

## Pipe Operator

```vibe
x |> f            // f(x)
x |> f(a, b)      // f(x, a, b)   — value is prepended
x |> f(a, _)      // f(a, x)      — `_` marks where the value goes
x |> g(a, _, b)   // g(a, x, b)
x |> f |> g       // g(f(x))
arr |> Array::length
s |> String::trim |> String::length
```

Without a `_`, the piped value becomes the **first** argument. A bare `_` in
the call's arguments substitutes the value at that position instead (no
prepend). A *compound* placeholder such as `_ * 2` is a section lambda
(`(v) -> v * 2`), not a pipe slot — so `xs |> Array::map(_, _ * 2)` reads as
`Array::map(xs, (v) -> v * 2)`.

**Method-style calls** (#736): `xs.length()` and `xs |> length` resolve to
`List::length(xs)` when `xs`'s type is a USER type declaring the method as a
top-level fn — importing just the type is enough
(`import ./list.vibe { List, list_of3 }` makes `list_of3(1,2,3) |> length`
work). A struct FIELD of the same name wins over a method (field-stored
function call), and a lexically visible bare function keeps normal call
semantics. Builtin receivers (`Array`/`String`/...) keep their builtin
`Type::method` forms — no bare-method sugar for them.

### Function combinators (point-free)

`compose` / `identity` / `flip` live in the prelude (`lib/@vibe/prelude/func.vibe`);
import them before use (`import ./func.vibe { compose, identity, flip }`).

```vibe
// vibe has no `>>` compose operator (`>>` is arithmetic shift) — use functions
compose(f, g)            // (x) -> g(f(x))   apply f then g
identity                 // (x) -> x         no-op stage / default
flip(f)                  // (b, a) -> f(a, b)
Array::map(xs, compose(parse, render))
```

> Runnable reference for the pipe `_` slot, combinators, `let*`, and `tap`:
> [`lib/@vibe/prelude/pipeline_ergonomics_test.vibe`](../lib/@vibe/prelude/pipeline_ergonomics_test.vibe)
> (`vibe test lib/@vibe/prelude/pipeline_ergonomics_test.vibe`). `Result`, `tap*`,
> and the combinators are prelude exports, so a file must `import` them and sit
> where it can reach the prelude — `import` paths may not escape the file's root
> directory, so standalone `examples/` files cannot reach `lib/@vibe/prelude/`.

## Control Flow

```vibe
// if (expression)
let v = if cond { a } else { b }

// match
match opt {
  Some(x) if x > 0 => x,     // guard
  Some(_) => 0,
  None => -1,
}

// while
while cond { body }

// for-in (collects into array)
for x in arr { x * 2 }         // -> Array
for i, x in arr { i + x }      // with index
for await b in pull { b }      // async iterator (struct: next() -> Future[Option[(T,Self)]], await-driven) or a () -> Option[T] pull closure (-> None)

// loop (parameterized tail-recursion)
let result = loop (i = 0, sum = 0) {
  if i >= 10 { break sum }
  continue(i + 1, sum + i)
}

// return (early exit from the enclosing function)
let find_first_neg: (Array[Int]) -> Int = (arr) -> {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 { return i }   // escapes the function, not just the loop
    i = i + 1
  }
  -1
}
```

## Pattern Matching

```vibe
_                   // wildcard
x                   // binding
42, "hi", true      // literal
Some(x)             // constructor
(a, b, c)           // tuple
record { x, y }     // record
Point::{ x, y }     // struct
A | B               // or-pattern
x if x > 0          // guard (match arm only)
```

### Destructuring let

```vibe
let (a, b) = (1, 2)
let record { x, y } = r          // any field names bind
let Some((x, y)) = pt            // ctor pattern (partial: traps on mismatch)

// let-else: bind on match, else run a DIVERGING fallback (#760)
let Some(v) = opt else { return -1 }   // else must return / throw
use(v)                                  // v is in scope past the let-else
```

> **let-else semantics (#760):** `let PAT = e else { alt }` desugars to
> `match e { PAT => <rest>, _ => alt }`, so `alt` must diverge (`return` /
> `throw`) — its arm has to unify with the continuation. For a fall-through
> *value* fallback, use an explicit `match`/`if … is` instead.

### is expression

```vibe
if expr is Some(v) { use(v) }   // bind + test
expr is None                     // -> Bool
```

## Type Definitions

```vibe
type Pair = (Int, Int)                   // alias

enum Color { Red; Green; Blue } derive(Eq)
enum Shape { Circle(Int); Rect(Int, Int) }

struct Point { x: Int; y: Int } derive(Eq, Ord, Show)
let p = Point::{ x: 1, y: 2 }
p.x                                       // field access
// struct derive(Ord) -> Point::compare(a, b) : Int   (-1 / 0 / 1, lexicographic)
// struct derive(Show) -> Point::to_string(p) : String ("Point { x: 1, y: 2 }")
// (Eq is a no-op marker; Hash / Default and enum derive are not yet generated)

trait Eq
trait Ord: Eq                              // supertrait
export open trait Show                     // extensible outside module

impl Eq for Int
impl [T: Eq] Eq for Array[T]              // conditional impl
```

## Collections

```vibe
// Array
let a = [1, 2, 3]
a[0]                          // index
Array::length(a)
Array::map(a, _ * 2)            // r# escapes keyword

// Tuple
let t = (1, "two", true)
t.0                           // => 1

// Record
let r = record { name: "vibe", ver: 1 }
r.name                        // => "vibe"  (dot access)
r.ver                         // => 1
let record { name: n, ver: v } = r   // destructuring binds any field name

// Map
let m = map { "key": 42 }
m["key"]

// Builders (mutable construction)
let b = ArrayBuilder::new()
ArrayBuilder::push(b, 1)
ArrayBuilder::freeze(b)       // -> Array[Int]

// Bytes — growable byte buffer
let e = Bytes::new()          // empty (length 0), grows via push/append
let z = Bytes::new(4)         // length 4, zero-filled (MoonBit semantics)
Bytes::set(z, 0, 65)          // in-bounds write (OOB index traps, #811)
Bytes::push(z, 9)             // append -> length 5
Bytes::get(z, 0)              // => 65
Bytes::length(z)              // => 5

// Int64Array — fixed-size i64-cell buffer for 32-bit word workloads.
// linear `Array[Int]` cells are 32-bit (with a 2-bit tag), so values
// >= 2^30 truncate; use Int64Array for hash / binary-protocol word
// buffers (SHA-1 schedule, etc.) where full 32/62-bit Ints must survive.
let w = Int64Array::make(4, 0)   // length 4, default 0
Int64Array::set(w, 0, 0xffffffff)
Int64Array::get(w, 0)            // => 4294967295 (no truncation)
Int64Array::length(w)            // => 4
```

> **selfhost status (#760):**
> - **Record dot access** (`r.name` on an anonymous `record { ... }`) works
>   (#760): a `binding.field` read on an anonymous-record binding lowers to the
>   same positional field read the destructure uses. Destructuring
>   (`let record { name: n } = r`) also binds any field name.
> - **`map { ... }` literals + `Map::*` builtins + `m[k]` indexing** work
>   standalone (#760): `Map::get` / `has_key` / `set` / `keys` and the `m["k"]`
>   index sugar all lower correctly. (`lib/@vibe/core`'s `get`/`get_or`/
>   `has_key`/`keys`/`values` remain available for a richer Map API, #766.)

## Effects (core concept)

vibe is **pure by default**. Side effects are tracked in the type system.

### Result-first pipeline (recommended)

> **selfhost status (#760):** `Result` (`Ok`/`Err`, `Result::Ok`/`Result::Err`,
> `Result[T, E]`) is available standalone — the compiler auto-provides
> `enum Result[T, E] { Ok(T); Err(E) }` for any program that references it and
> neither declares nor imports its own. Declaring or importing a `Result` (e.g.
> a single-param `enum Result[T] { Ok(T); Err(String) }`) overrides the built-in
> one. `Option` (`Some`/`None`) is built in as a first-class type. Both the
> `let*`/`?` railway on `Result` and on `Option` work standalone.

```vibe
let parse_id: (String) -> Result[Int, String] = (raw) -> { ... }
let validate_id: (Int) -> Result[Int, String] = (id) -> { ... }
let load_user: (Int) -> Result[String, String] = (id) -> { ... }

let fetch_user: (String) -> Result[String, String] = (raw) -> {
  raw
  |> parse_id
  |> Result::and_then(validate_id)
  |> Result::and_then(load_user)
}
```

### Railway bind (`let*`) — `Result` and `Option` (#635)

`let* x = e` unwraps the success case and binds `x`, or short-circuits the whole
block with the failure case. The lowering is **type-directed by `e`'s type**:

- `e: Result[T, E]` → `match e { Ok(x) => <rest>, Err(e) => Err(e) }`
- `e: Option[T]`    → `match e { Some(x) => <rest>, None => None }`

so the enclosing function must return the matching `Result`/`Option`. Handy when
stages need names instead of point-free `and_then`:

```vibe
let fetch_user: (String) -> Result[String, String] = (raw) -> {
  let* id    = parse_id(raw)       // Err short-circuits the block
  let* valid = validate_id(id)
  load_user(valid)                 // last expr is the block's Result
}

let pair: (Int, Int) -> Option[Int] = (a, b) -> {
  let* x = half(a)                 // None short-circuits the block
  let* y = half(b)
  Some(x + y)                      // last expr is the block's Option
}
```

**Adopted scope (#635, "option 1: built-in set extension"):** `let*`/`?` are
generalized to the compiler's built-in short-circuit set — `Result` and
`Option` — *only*. A user-extensible `Try`/`Bind` trait (option 2) is **deferred**
(it depends on method-bearing traits). **No implicit conversion** between the two:
a block returns one type, so mixing `Result` and `Option` in one `let*`/`?` chain
is a type error (e.g. `return type mismatch: expected Option[Int], got
Result[Int, String]`). Type direction is **best-effort syntactic inference** on
the operand's head type (a function's declared return head, a local binding's
inferred type, a constructor's enum); when **undeterminable, it defaults to
`Result`** (the historical behavior) — so annotate the operand's source (e.g. a
function return type) if a borderline `Option` case is misread as `Result`.

### Debugging a pipeline (`tap`)

`tap` runs a side effect on the value and returns it unchanged — observe a
stage without breaking the `|>` chain. Railway variants `tap_ok` / `tap_err` /
`tap_some` observe only one track. They are prelude exports
(`lib/@vibe/prelude/io.vibe`); import them and note they carry the `Stdout` effect:

```vibe
x
|> tap((v) -> stdout_write("step: \{v}\n"))
|> next_stage

result |> tap_ok((v) -> stdout_write("ok\n")) |> tap_err((e) -> stdout_write("err\n"))
```

### Error boundary (`throw` / `handle`)

```vibe
let risky: (Int) -> Int with { Error } = (x) -> {
  if x == 0 { throw("division by zero") }
  100 / x
}

// handle catches the effect
let safe = handle { risky(0) } with Error { Throw(msg) => -1 }
```

### Railway try (`?`) — `Result` and `Option` (#635)

`e?` unwraps the success case and yields the inner value, or **early-`return`s**
the failure case from the enclosing function. Like `let*`, the lowering is
**type-directed by `e`'s type**:

- `e: Result[T, E]` → `match e { Ok(v) => v, Err(err) => return Err(err) }`
- `e: Option[T]`    → `match e { Some(v) => v, None => return None }`

```vibe
let sum_checked: (Int, Int) -> Result[Int, String] = (a, b) -> {
  let x = checked(a)?              // Err early-returns from sum_checked
  let y = checked(b)?
  Ok(x + y)
}

let sum_halves: (Int, Int) -> Option[Int] = (a, b) -> {
  let x = half(a)?                 // None early-returns from sum_halves
  let y = half(b)?
  Some(x + y)
}
```

Same adopted scope as `let*` above: built-in `Result`/`Option` only, no implicit
conversion, best-effort type direction defaulting to `Result` when
undeterminable. (The deferred `Try` trait — option 2 — would let user types opt
in; it is not implemented.)

### suberror (typed errors)

```vibe
suberror NotFound(String)
suberror InvalidInput(Int, String)   // tuple payload only
```

### User-defined effects (algebraic)

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }

effect Logger {
  Log(String) -> Unit
}

let greet: (String) -> Unit with { Logger } = (name) -> {
  perform Logger::Log("hello \{name}")
}

// the handler arm calls stdout_write, so the enclosing function carries Stdout
let main: () -> Unit with { Stdout } = () -> {
  handle { greet("world") } with Logger {
    Log(msg) => {
      stdout_write(msg)
      resume(())         // continue where perform left off
    }
  }
}
```

継続呼び出しは `resume(v)` が canonical (one-shot tail-resumptive, ADR-0050)。
> **replay 実装の制約 (#817 まで)**: 現行の handler は resume 時に handle
> body を**先頭から再実行** (replay) する実装のため、handle body 内の
> 副作用 (print / `let mut` の更新など) は perform ごとに再実行される。
> **handle body は最後の perform まで pure に保つこと** — 副作用や
> 可変状態の蓄積は handler arm 側か handle の外に置く。この制約は
> evidence-passing handler 移行 (#817) で解消予定。

operation の宣言 arity より 1 つ多い末尾パラメータを束縛する `k` 規約
(`Emit(v, k) => v + k(0)`、non-tail 継続) は **旧 MoonBit fixture runner
専用だった機能で、selfhost build path では未サポート** — checker が
`non-tail continuation binder (k-convention) is not supported by the build
path` と reject する (#814)。非 tail 継続は evidence-passing handler 移行
(#817) で対応予定。継続呼び出しは `resume(v)` を使う。
規約の詳細は [archive/mut-effect-plan.md](archive/mut-effect-plan.md) の
「継続呼び出し規約」(#627) を参照。

### Effect polymorphism

```vibe
let apply: [T](f~: (T) -> T with { e }, x~: T) -> T with { e } = (f~, x~) -> {
  f(x)
}
```

## Module System

```vibe
// export
export let f: (Int) -> Int = (x) -> { x + 1 }
export enum Color { Red; Green; Blue }
export { name1, name2 }
export ./lib.vibe { helper1, helper2 }  // re-export

// import
import ./lib.vibe { func1, func2 }
import ./lib.vibe { func1 as renamed }
import ./lib.vibe { type MyType, trait Show }
import ./subdir { helper }   // directory import -> subdir/index.vibe(i)
import . { helper }          // own directory's index (same resolution)

// module blocks (`module Math { ... }`) are REMOVED (#728, ADR-0063):
// use file boundaries + import/export. `Type::method` / `Effect::Op`
// qualified access is an independent mechanism and remains.
```

Package refs: `@json`, `@lib/path` (hyphen/slash are part of name after `@`).
Qualified access: `Type::method`, `Module::name`.

## Tests

```vibe
test "arithmetic" {
  assert_eq(1 + 1, 2)
  assert(eq("a", "a"))
}
```

```bash
vibe test file.vibe
vibe test dir/            # run all tests in directory
```

## Key Builtins

**String**: `String::length`, `concat`, `substring`, `contains`, `index_of`, `split`, `trim`, `replace`, `starts_with`, `ends_with`, `join`

**Array**: `Array::length`, `get`, `slice`, `map`, `filter`, `fold`, `find`, `any`, `all`, `reverse`, `concat`

**Map**: `Map::get`, `has_key`, `keys`, `values`, `set`

**I/O** (require effects):
```vibe
stdout_write(s)    // with { Stdout }
stdin_read_line()  // with { Stdin }
sh("ls -la")       // with { Stdout } - shell command
sh_lines("ls")     // -> Array[String]
```

**Profiling** (require `Profiler` effect; linear backend only; use the
direct-call surface — unhandled `perform` throws):
```vibe
Profiler::now_us()      // with { Profiler } - elapsed µs (wall clock)
Profiler::heap_bytes()  // with { Profiler } - current bump-heap pointer
                        // (bytes allocated); deltas attribute allocation the
                        // way now_us deltas attribute time (heap never shrinks)
```

**Conversion**: `Int::to_string`, `Int::to_double`, `Double::to_int`, `String::from_char_code`, `Int::parse(s) -> Option[Int]` (10 進、先頭 `-` 可; 空文字列・非数字・`Int::max_value` 超えは `None`)

## Idioms

```vibe
// Result composition (railway-style)
let result =
  read_config()
  |> Result::and_then(parse)
  |> Result::and_then(process)

// Boundary at the edge
let value = handle { risky(0) } with Error { Throw(_) => default_value }

// Builder pattern
let arr = {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
}

// for-in as map
let doubled = for x in xs { x * 2 }

// pipe chain
input
  |> String::trim
  |> String::split(",")
  |> Array::map(_, parse_int)
```

## Conditional Compilation (`#cfg`)

```vibe
#cfg(dev)
let debug_dump = (x) -> { ... }   // exists ONLY when the `dev` flag is active

#cfg(dev)
let main = () -> Int { debug_dump(run()) }

#cfg(release)
let main = () -> Int { run() }
```

- Activate flags at compile time: `VIBE_CFG=dev vibe build app.vibe` (comma-separated for multiple).
- A `#cfg(flag)` statement whose flag is inactive is parsed (syntax must stay valid, like Rust's `cfg`) and **dropped before checking/codegen** — zero bytes in the output binary.
- Top-level statements only (`let` / `enum` / `struct` / `impl` / ...).
- `vibe fmt` / normalize refuses `#cfg` sources (formatting would delete disabled code).
- Not usable inside the compiler's own source until the seed compiler understands it (see docs/selfhost-bootstrap.md).

## RC Debug Mode (`VIBE_RC=shadow`)

`VIBE_RC=shadow vibe build app.vibe` compiles on the Perceus RC path with **shadow-liveness instrumentation**: every freed heap block is marked in a shadow byte table, and the FIRST `rc_dup`/`rc_drop` touching a freed block executes `unreachable` — a deterministic trap at the faulting operation, instead of free-list corruption that crashes later at an unrelated location ("moving target", see issue #715). Debug-only: adds a memory pad + per-dup/drop checks. Normal builds (`VIBE_RC=1`/unset) are byte-identical to before this feature.

## File Conventions

| File | Purpose |
|------|---------|
| `*.vibe` | Source |
| `index.vibe` | Package entry (exports `version`) |
| `index.lock` | Dependency lock |
| `*_test.vibe` | Tests |

---

*Full reference: [docs/spec/syntax.md](spec/syntax.md) / [syntax-reference.md](language-tour/syntax-reference.md) / [language-tour/](language-tour/)*

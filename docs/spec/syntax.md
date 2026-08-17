# vibe Syntax Specification

Status: implemented surface syntax reference.

This document is the canonical index for vibe syntax. It describes accepted
source forms, preferred style, and compatibility forms. Type-system and runtime
semantics live in `docs/vibe.md`; tutorial material lives in
`docs/cheatsheet.md`.

Implementation sources:

- `lib/@vibe/parser/lexer.vibe` and `lib/@vibe/parser/parser*.vibe` — the
  lexer/parser contract package (`lib/@vibe/compiler/syntax/` re-exports it
  for the compiler's internal import spellings)
- `fixtures/*.vibe` and `examples/*_test.vibe` for executable syntax coverage

When changing grammar, update this file, parser tests/fixtures, formatter
round-trip coverage, and any affected cheatsheet examples in the same
change.

## Notation

- `Name` is a value/type/module identifier.
- `Type` is a type expression.
- `Expr` is an expression.
- `Pat` is a pattern.
- `Stmt` is a declaration, command, assignment, or expression statement.
- `...` means a separated repetition: comma-separated in expression contexts
  (arguments, tuples, struct literals, import lists), semicolon-separated in
  type declaration bodies (enum variants, struct fields). Using `,` as a
  declaration-body separator was removed in 0.3.0 and is a parse error.

This document is intentionally EBNF-like, not a parser generator grammar.
Parser conflict resolution and diagnostics are implementation-defined.

## Lexical Forms

### Comments

```vibe
// line comment
```

### Identifiers

```text
name
snake_case
TypeName
r#if
```

Rules:

- User code should use lowercase `snake_case` for values/functions.
- Type, enum, struct, trait, effect, and constructor names conventionally start
  with uppercase.
- `r#keyword` forces identifier interpretation for reserved words. Exception:
  `fn` has no raw-identifier escape (#1280) — `r#fn` still lexes as the `fn`
  keyword, so no binding/parameter/type/member can be named `fn`.
- Qualified names use `::`: `Array::map`, `Module::name`, `Point::{ ... }`.
- Field and tuple access use `.`: `record.name`, `tuple.0`.
- Package/module refs after `@` may contain `/` and `-`: `@pkg/path`.

### Keywords

Reserved keywords:

```text
let rec mut fn if else match while loop for in break continue yield
throw perform resume handle with effect suberror
test example bench enum struct trait impl type import export module extern internal
as true false do derive
```

Context-sensitive syntax heads:

```text
record map
```

`map` is not a reserved keyword. `record` and `map` introduce collection
literals only where the parser is expecting that literal head.

### Literals

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
42
0xFF
1.5f
3.14
"hello \{name}"
#|multi
#|line
'A'
true
false
()
```

Rules:

- `Int` literals are 62-bit tagged integers. Accepted range is
  `-4611686018427387904` through `4611686018427387903` (#1877: the 63-bit
  representation range); positive literal tokens above `4611686018427387903`
  are rejected.
- Hex literals use `0x` or `0X`.
- Decimal literals without `f` are `Double`; decimal literals with `f` are
  `Float`.
- Strings support escapes and interpolation with `\{Expr}`. The former
  `\(Expr)` spelling was removed in 0.3.0 and is now a lex error. A `String`
  is a byte string: `String::length`, indexes, slices, and iteration use byte
  counts/offsets, and iteration yields byte-valued `Int`s. Use
  `String::byte_at` and `String::from_byte` for single-byte operations;
  Unicode code-point or grapheme semantics are not implied.
- `Char` is a transparent `Int` alias used as a readability hint. A character
  literal such as `'A'` is numeric literal syntax (the byte value `65`), not a
  distinct Unicode-scalar type; `Char` and `Int` unify without conversion.

## Program Structure

```text
Program ::= Stmt*
Block   ::= "{" Stmt* Expr? "}"
```

Top-level statements may declare values, types, modules, imports/exports,
tests, benches, or final expressions. Blocks evaluate to their last expression
when present; otherwise they evaluate to `Unit`.

## Declarations

### Values

Preferred style separates the function type from the function body:

```vibe
let x: Int = 42
let total = {
  let mut counter: Int = 0
  counter += 1
  counter
}
let rec fact: (Int) -> Int = (n) -> {
  if n < 2 { 1 } else { n * fact(n - 1) }
}
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let id: [T](T) -> T = (x) -> { x }
let show: [T: Eq + Ord](T) -> T = (x) -> { x }
```

Top-level named functions use `fn`. They require parameter and return type
annotations, support generic parameters and effect rows, and lower to the
same recursive `let` representation before checking and code generation:

```vibe
fn add(x: Int, y: Int) -> Int { x + y }
fn identity[T](x: T) -> T { x }
fn log(message: String) -> Unit with Stdout {
  Stdout::write_stream(message)
}
export fn doubled(x: Int) -> Int { x * 2 }
```

`fn` is top-level only; use the typed `let` forms above for lambdas and local
functions.

Accepted forms:

```text
"let" Name TypeAnn? "=" Expr
"let" "mut" Name TypeAnn? "=" Expr
"let" "rec" Name TypeAnn? "=" Expr
"let" Pat "=" Expr
"guard" Expr "is" Pat "else" Block
```

Compatibility:

- Inline parameter type functions such as
  `let f = (x: Int) -> Int { x }` are accepted for compatibility but
  deprecated. Formatter migrations should prefer
  `let f: (Int) -> Int = (x) -> { x }`.
- Top-level `let mut` is rejected; local mutation is block-scoped.

### Functions And Lambdas

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
(x) -> { x + 1 }
(x, y) -> { x + y }
x -> x * 2
_ * 2
_ + _
```

Function types:

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
() -> Int
(Int, String) -> Bool
(Int) -> Int with Exception
[T](T) -> T
[T: Eq + Ord](T) -> Bool
```

Labeled arguments:

```vibe
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
export let two: () -> Int = () -> { f(x = 1, y = 2) }
```

`x~` is a required labeled parameter. A call site is either ALL positional or
ALL labeled; mixing them is rejected ("call to f mixes positional and labeled
arguments"). Default values in parameter lists are not part of the current
surface syntax.

`x?` is an optional parameter (#1500). It is declared at type `Option[T]` and
the call site may omit it:

```vibe
fn describe(x: Int, note?: String) -> String {
  match note {
    Some(s) => s,
    None => "none"
  }
}

export let a: () -> String = () -> { describe(1) }
export let b: () -> String = () -> { describe(1, "hi") }
```

Rules:

- Inside the body the parameter is bound at `Option[T]`, never at `T` — an
  omitted argument has to produce a value, and `None` is that value.
- A function TYPE spells it the same way, and means the same thing:
  `(Int, note?: String) -> String` is `(Int, Option[String]) -> String`.
- The call site writes the payload, not the `Option`: `describe(1, "hi")`,
  not `describe(1, Some("hi"))`. `desugar_optional_args` wraps supplied
  arguments in `Some` and fills omitted trailing ones with `None` before
  checking, so the ordinary arity check sees a full argument list.
- Only TRAILING optional parameters may be omitted. A call that is short by a
  required parameter is still an arity error, and still reports the real count.
- Labeled and positional supply both work, under the usual all-positional or
  all-labeled rule: `describe(x = 1, note = "hi")` and `describe(x = 1)`.

### Type Aliases

```vibe
type Pair = (Int, Int)
export type Ids = Array[Int]
```

### Enums

```vibe
enum Option[T] {
  Some(T);
  None
}

enum Color { Red; Green; Blue } derive(Eq)
export enum Shape { Circle(Int); Rect(Int, Int) }
```

Constructors may be used in expressions and patterns.

Declaration members (enum variants, struct fields) are separated by `;`.
Using `,` as the separator was removed in 0.3.0; the parser reports a located
error suggesting `;`.

### Structs

```vibe
struct Point { x: Int; y: Int } derive(Eq)
let p = Point::{ x: 1, y: 2 }
```

### Traits And Impl

```vibe
trait Eq
trait Ord: Eq
export open trait Show

impl Eq for Int
impl [T: Eq] Eq for Array[T]
```

Trait bodies are currently narrow and method-bearing trait support is
implemented only where covered by checker/codegen tests.

A **marker trait** (one declared with no methods, like `Eq` above) dispatches
to the builtin `==` / `<`. `==` on `Array` / `Bytes` is rewritten to a
structural compare **only where the element type is statically known**
(#1526 / ADR-0097); inside a `[T: Eq]`-bounded function the `T` is erased —
no element type — so the builtin falls back to reference equality there. A
marker-trait impl on a container therefore **is declarable but is not
honoured as a bound** — passing an `Array` to a `[T: Eq]` parameter is
rejected, with a diagnostic that says the impl exists and why it was refused. Give the trait a method and the impl
resolves through the witness dictionary instead, in either spelling
(`impl M for Array[Int]` or `impl [T] M for Array[T]`). See #1503.

### Effects

```vibe
effect Logger {
  Log(String) -> Unit
}

effect State[T] {
  Get() -> T;
  Put(T) -> Unit
}
```

### Suberrors

```vibe
suberror NotFound(String)

suberror AppError {
  Io(String);
  Parse(Int)
}
```

### Modules

Source files are modules. Module blocks such as `module Math { ... }` are
rejected; use a file boundary with explicit imports and exports instead:

```vibe skip
// math.vibe
export let abs: (Int) -> Int = (x) -> {
  if x < 0 { 0 - x } else { x }
}

// main.vibe
import ./math.vibe { abs }
abs(-5)
```

`module` remains a reserved compatibility token, not a module-block
declaration. `Type::method` and `Effect::Op` are qualified names independent
of file modules.

### Extern

```vibe
extern let %host_name: Type
```

Extern declarations are for compiler/runtime boundary code, not ordinary user
programs.

## Imports And Exports

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program (the `./lib.vibe` it imports is illustrative)
import ./lib.vibe { foo, bar as baz }
import ./lib.vibe { type Pair, trait Show, foo }
import ./lib.vibe { Int }
import ./lib.vibe { Int::to_string as int_to_string }

export let f: (Int) -> Int = (x) -> { x + 1 }
export enum Color { Red; Green; Blue }
export { f, Color }
export ./lib.vibe { helper }
```

Rules:

- Imports are source-first: `import <module-ref> { items }`.
- `type` and `trait` item qualifiers select non-value namespaces.
- `Name::member` imports a single type/module member.
- `import <module-ref> { Name }` may activate a namespace for `Name::*`.
- `export <module-ref> { ... }` re-exports selected items from another module.
- Legacy `use <module-ref> { ... }` is not part of the current surface syntax.

Which module refs a given file is *allowed* to import — package boundaries,
owner visibility, implicit build roots, and the dependency pin/update
workflow — is not syntax and is specified once, in
[docs/module-system-oracle.md の「現行モデル」節](../module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)
(#1269).

## Expressions

### Blocks

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
{
  let x = 1
  let y = 2
  x + y
}
```

### Control Flow

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
if cond { a } else { b }

match value {
  Some(x) if x > 0 => x,
  Some(_) => 0,
  None => -1,
}

while cond { body }

for x in xs { x * 2 }
for i, x in xs { i + x }

loop {
  if done { break }
}

loop (i = 0, acc = 0) {
  if i >= 10 { break acc }
  continue(i + 1, acc + i)
}
```

Rules:

- `if` and `match` are expressions.
- `while` is statement-like and returns `Unit`.
- `for-in` collects body results into an array.
- `while`, bare `loop { ... }`, and `for-in` accept only bare `break`. A payload
  is rejected rather than evaluated and discarded. `while` and bare `loop`
  return `Unit`; `for-in` returns the results collected before the break.
- `break Expr` returns a value only from parameterized `loop (...)`, and the
  payload must start on the same line as `break`. `break(acc)` is parsed as
  `break` followed by a parenthesized expression -- NOT the same shape as
  `continue(a, b)`'s call-like next-state argument list. `break(a, b)` builds
  the tuple `(a, b)`, it does not break with two separate loop-result values
  (see `book/src/02_control_flow.vibe.md`'s loop section for a runnable
  example of this asymmetry).
- Parameterized `loop (...)` is tail-recursive state threading.
- `continue` and `break` count different things, and #1284 settled that the
  asymmetry stays: `continue(..)` passes the loop's PARAMETERS (exactly as many
  as `loop (..)` declares), while `break e` passes the loop's single RESULT --
  a `loop` is an expression with one value, so there is no arity for `break` to
  match. To keep the two distinguishable at the point of confusion, a
  `continue` whose argument count differs from the parameter count is a parse
  error naming both counts. A bare `continue` (no argument list) means "repeat
  with every parameter unchanged" and stays legal.
- Avoid naming a top-level function `f` or `g`: those identifiers collide
  with `@vibe/prelude/func.vibe`'s `compose`/`flip` combinator parameter
  names and can produce invalid wasm at codegen time (checker passes,
  `vibe run` fails to instantiate) -- tracked in #1203. Not a general
  language ambiguity, just a known name-collision gap in the current
  codegen; use any other identifier.

### Calls, Fields, Indexing

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
f(x)
f(x=1, y=2)
Array::map(xs, _ * 2)
point.x
tuple.0
arr[0]
arr[:]
arr[:end]
arr[start:]
arr[start:end]
map_value["key"]
arr[0] = value
```

`.` supports field/tuple access and user-type method calls. A declared
user-type method may be called as `recv.method(args)`; its canonical normalized
spelling is `Type::method(recv, args)`. The single-file normalizer performs
that rewrite only when it can recover the receiver type locally, and otherwise
leaves the dot form unchanged rather than guessing. Builtins use qualified or
pipe-style calls (for example `String::length(s)`), while a function stored in
a field must be invoked as `(obj.callback)(args)`.

Slice syntax accepts exactly the four forms `value[:]`, `value[:end]`,
`value[start:]`, and `value[start:end]`. The receiver must be a `String`,
`Bytes`, or `Array[T]`; the result has the same type as the receiver (including
the `T` in `Array[T]`). An omitted start means `0`, and an omitted end means the
receiver's length. Both explicit bounds are `Int`. String bounds are byte
offsets, not Unicode code-point or grapheme offsets.

### Collections

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
[1, 2, 3]
(1, "two", true)
record { x: 1, y: 2 }
record { x, y }
Map::from_pairs([("key", 42)])
Map::new()
```

The former `map { "key": 42 }` literal was removed (#960); the `Map::` API
spellings above are parse-level desugars into the same map node, and the old
literal reports a located parse error naming the replacement.

### Effects And Error Boundaries

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
throw("message")
risky()?

perform Logger::Log("hello")

handle { risky() } with Exception {
  Throw(msg) => -1
}

handle { greet("world") } with Logger {
  Log(msg) => {
    resume(())
  }
}
```

An ordinary function may expose a user-defined effect in its `with` row so a
caller can handle it. A program entry (`main` or `_start`) cannot: only standard
host-provider effects (`Fs`, `Env`, `Stdout`, and the other provider labels),
entry-boundary `Exception`, and runtime-managed `Async` may remain there. Handle
a user effect before it reaches the entry boundary:

Admission follows operation ownership, not just the base effect spelling. A
user operation `Fs::Custom` does not acquire the standard `Fs` host provider;
the registry-owned `Fs::read_file` remains host-owned when an unrelated linked
module declares another effect named `Fs`.
Entry rows are closed contracts, so a row variable such as `with e` must be
made concrete before the entry boundary.

```vibe
effect Ask {
  Get() -> Int
}

fn ask() -> Int with Ask::Get {
  perform Ask::Get()
}

fn main() -> Int {
  handle { ask() } with Ask {
    Get() => resume(42)
  }
}
```

## Operators

Precedence is high to low.

| Prec | Operators | Assoc | Notes |
|------|-----------|-------|-------|
| 1 | `.`, `()`, `[]` | left | field, call, index |
| 2 | unary `-`, `!` | right | numeric negation, bool not |
| 3 | `*`, `/`, `%` | left | |
| 4 | `+`, `-` | left | |
| 5 | `<<`, `>>` | left | `>>` is arithmetic shift |
| 6 | `&` | left | bitwise and |
| 7 | `^` | left | bitwise xor |
| 8 | `|` | left | bitwise or |
| 9 | `==`, `!=`, `<`, `<=`, `>`, `>=` | non-assoc | comparisons do not chain |
| 10 | `|>` | left | pipe |
| 11 | `&&` | left | short-circuit |
| 12 | `||` | left | short-circuit |

Assignments are statements, not expressions:

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
x = value
x += 1
x -= 1
x *= 2
x /= 2
x %= 2
```

## Pipe

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
x |> f
x |> f(a, b)
x |> f |> g
arr |> Array::length
```

`lhs |> rhs(args...)` desugars to `rhs(lhs, args...)`.

## Patterns

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
_
x
42
"hello"
true
Some(x)
(a, b)
record { x, y }
Point::{ x, y }
A | B
```

Match-arm guards:

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
match x {
  v if v > 0 => v,
  _ => 0,
}
```

Destructuring:

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
let (a, b) = pair
let record { x, y } = rec
guard opt is Some(v) else { return -1 }
if opt is Some(v) { v } else { 0 }
```

`guard <scrutinee> is <pattern> else <block>` (#1283) is the refutable binding
form. It desugars to `match <scrutinee> { <pattern> => <rest-of-block>, _ =>
<block> }`, so the `else` block is the continuation's fallthrough and must
leave the enclosing function on every path. `return` is the only divergence
form accepted for now (`throw` is deferred: ADR-0073 pins `Error::Throw` as
checked and non-resumable, but the checker's explicit abortive-effect
judgement is separate work). Use `if <scrutinee> is <pattern> { .. } else
{ .. }` when the fallback produces a value rather than exiting.

`guard` is a reserved word. A binding that needs the name spells it `r#guard`.

The earlier `let PAT = value else { .. }` (let-else, #760(1)) is retired and
rejected by name. It is not a synonym: its `else` block produced the value of
the whole remaining block, so a non-diverging one silently replaced the rest
of the function.

## Types

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
Int
Float
Double
Bool
Char
String
Unit
i32
f32
f64

Array[T]
Map[K, V]
Option[T]
(Int, String)
(Int, String) -> Bool
() -> Int with Exception
[T](T) -> T
[T: Eq + Ord](T) -> Bool
```

Rules:

- `i32`, `f32`, and `f64` are aliases for `Int`, `Float`, and `Double` in type
  positions.
- Function effects appear after return type: `-> T with Effect`.
- Effect row variables such as `with e` are accepted in polymorphic
  higher-order signatures.
- The effect row has one spelling, plus one for the empty row:

  | spelling | |
  | --- | --- |
  | `with A + B` | the row |
  | `with ()` | the explicitly empty row |

  `with { A, B }` was the pre-#1429 spelling. It was accepted alongside the
  new one while the tree was converted -- both parsed to the same row, so
  nothing after the parser could tell them apart -- and is now rejected by
  name. The parser had to take both for the length of the migration because
  the bootstrap rule ([bootstrap.md](../bootstrap.md)) requires the seed to
  understand a spelling before the compiler's own source may use it. `vibe
  fmt` still rewrites it: the formatter normalizes rows at the TOKEN level, so
  it converts source the compiler no longer accepts, which makes it the
  migration path for code outside this repository.

  `effectset` keeps its braced member list (`effectset FsAll = { Fs::read_file,
  Fs::write_file }`) -- that `{ .. }` is a set literal on the right of `=`, not
  a `with` row, and it never had a braceless spelling to collapse into.

- The exception effect is spelled `Exception`. `Error` was its name through the
  ADR-0085 migration and is now rejected by name (#1461, #1501) in BOTH places
  a source effect name appears -- a row item (`-> T with Error`) and the handled
  effect (`handle { .. } with Error { .. }`). #1461 covered only the first, so
  for one release the two positions disagreed while `vibe fmt` rewrote both;
  #1501 closed that. `vibe fmt` remains the migration path, on the same
  token-level argument as the braced row above.

  `perform Error::Throw(x)` is unaffected and stays legal. An operation
  qualifier is not a row item: it names the operation the runtime dispatches,
  and no row is being spelled there.

  The separator is `+`, not `,`, because a comma cannot be told apart from an
  enclosing list's comma once the braces are gone: in `((Int) -> Int with A, B)`
  the `B` is either a second label or a second tuple element, and in
  `fn g(cb: (Int) -> Int with A, x: Int)` it is either a second label or the
  next parameter. `+` can start neither a type nor a parameter name, so the
  row's end is unambiguous in every position with no lookahead. It is also
  already the language's "and another one" separator, in trait bounds
  (`[T: A + B]`).

  `()` spells the empty row and nothing else: a parenthesised NON-empty row
  (`with (A + B)`) is rejected by name rather than accepted as a second
  grouping syntax.

  Writing no `with` clause at all is not the same construct as `with ()` on an
  inline lambda -- there, omission means the row is inferred from the enclosing
  context. On a top-level declaration the two already agree: a declaration with
  no `with` clause is checked as empty, so performing an undeclared effect in
  one is a compile error.

## Resource Declarations

```vibe skip
resource Posts: S3::Bucket
```

ADR-0075 Phase 2 (#1343). Declares a nominal **logical resource identity** the
executable requires a binding for. It is not the resource's creation, declares
neither a value nor a type, and deliberately carries no physical name or
credential -- ADR-0075 keeps those on the host adapter, out of guest source.
It exists so a resource kind parameter can be instantiated by NAME
(`S3::Read[Posts]`).

The kind must be a **qualified path** (`Owner::Kind`). A bare name would be
indistinguishable from a type, and a resource kind is not a type.

`resource` is a **contextual keyword**: it starts a declaration only when an
identifier follows it, so `let resource = 1` / `resource = f()` /
`resource(x)` keep meaning what they did. (`effect` and `effectset` claim
their word unconditionally; this one does not, because `resource` is a far
more plausible variable name.)

Two identity rules are enforced:

* a name may be declared once -- including against the predeclared resources,
  so a program cannot shadow the ambient process root;
* nothing may be declared of a **singleton** kind. `Process::Root` is the one
  singleton today: its single inhabitant is `Process::Root` itself, so
  `resource Home : Process::Root` would be a second name for the same process.

A `resource` declaration cannot be `export`ed: ADR-0075 puts it at the
`.vibex` root only, and a reusable module abstracts over a resource KIND
parameter rather than naming a resource. (The `.vibex`-root restriction itself
is not yet enforced -- the checker does not know whether it is looking at an
entry file or a library module.)

Kind names are not themselves checked against a registry: there is no
resource-kind declaration syntax yet, so `S3::Bucket` has nowhere to be
declared. The qualified-path requirement is the only well-formedness rule a
kind carries today.

## Tests, Examples And Benches

```vibe skip
// doctest-skip: form catalogue: bare surface forms, not a compilable program
test "arithmetic" {
  assert_eq(1 + 1, 2)
}

example "adding two numbers" {
  assert_eq(add(1, 2), 3)
}

bench "hot path" {
  expensive()
}
```

The test name is a STRING literal. A bare identifier
(`test smoke_case { .. }`) is rejected -- `expected test name string` -- so the
name is always quoted. This section said both forms were accepted until it was
measured against the compiler; nothing was checking it, because docs/spec/ was
outside the doctest list.

`example "name" { .. }` (#819) is a documentation example. It is compiled and
RUN exactly like a test -- that is the point of the form: a doc sample that
stopped compiling is the failure it exists to prevent, and a sample that lives
in the source cannot be missed the way a Markdown file outside a hardcoded
check list can.

The default parse entry points lower it to a test, so no stage after the
parser distinguishes the two: it is checked, kept alive by DCE (an example is
a DCE root, so declarations only an example references survive), compiled and
executed as a test. The separate form survives only through the
`parse_*_preserving` entry points, which is what lets LSP hover and doc
extraction tell an example from a test.

Because examples are read as sample code, they are not held to lint rules that
would distort them -- in particular an unused binding inside an example is not
reported.

`example` is a reserved word, like `test` and `bench`. A binding that needs the
name spells it `r#example`.

## Deprecated Or Compatibility Forms

These forms may parse today but should not be used in new documentation:

- Inline parameter type function declarations:
  `let f = (x: Int) -> Int { x }`
- Legacy import/use forms outside `import <module-ref> { ... }`.
- User-type methods may use `recv.method(...)`, normalized to
  `Type::method(recv, ...)` when the receiver type is locally recoverable.
  Builtins use qualified or pipe-style calls; function-valued fields require
  `(obj.field)(...)`.
- `~` bit-not is not supported; use `x ^ mask`.

# vibe Syntax Specification

Status: implemented surface syntax reference.

This document is the canonical index for vibe syntax. It describes accepted
source forms, preferred style, and compatibility forms. Type-system and runtime
semantics live in `docs/vibe.md`; tutorial material lives in
`docs/language-tour/` and `docs/cheatsheet.md`.

Implementation sources:

- `lib/@vibe/parser/lexer.vibe` and `lib/@vibe/parser/parser*.vibe` — the
  lexer/parser contract package (`lib/@vibe/compiler/syntax/` re-exports it
  for the compiler's internal import spellings)
- `fixtures/*.vibe` and `examples/*_test.vibe` for executable syntax coverage

When changing grammar, update this file, parser tests/fixtures, formatter
round-trip coverage, and any affected language-tour examples in the same
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
- `r#keyword` forces identifier interpretation for reserved words.
- Qualified names use `::`: `Array::map`, `Module::name`, `Point::{ ... }`.
- Field and tuple access use `.`: `record.name`, `tuple.0`.
- Package/module refs after `@` may contain `/` and `-`: `@pkg/path`.

### Keywords

Reserved keywords:

```text
let rec mut fn if else match while loop for in break continue yield
throw perform resume handle with effect suberror
test bench enum struct trait impl type import export module extern internal
as true false do derive
```

Context-sensitive syntax heads:

```text
record map
```

`map` is not a reserved keyword. `record` and `map` introduce collection
literals only where the parser is expecting that literal head.

### Literals

```vibe
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
  `-2305843009213693952` through `2305843009213693951`; positive literal
  tokens above `2305843009213693951` are rejected.
- Hex literals use `0x` or `0X`.
- Decimal literals without `f` are `Double`; decimal literals with `f` are
  `Float`.
- Strings support escapes and interpolation with `\{Expr}`. The former
  `\(Expr)` spelling was removed in 0.3.0 and is now a lex error.
- `Char` is represented as an integer character code.

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
fn log(message: String) -> Unit with { Stdout } {
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
"let" Pat "=" Expr "else" Block
```

Compatibility:

- Inline parameter type functions such as
  `let f = (x: Int) -> Int { x }` are accepted for compatibility but
  deprecated. Formatter migrations should prefer
  `let f: (Int) -> Int = (x) -> { x }`.
- Top-level `let mut` is rejected; local mutation is block-scoped.

### Functions And Lambdas

```vibe
(x) -> { x + 1 }
(x, y) -> { x + y }
x -> x * 2
_ * 2
_ + _
```

Function types:

```vibe
() -> Int
(Int, String) -> Bool
(Int) -> Int with { Error }
[T](T) -> T
[T: Eq + Ord](T) -> Bool
```

Labeled arguments:

```vibe
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
f(x=1, y=2)

let g: (value?: Int) -> Int = (value?) -> {
  match value {
    Some(v) => v,
    None => 0,
  }
}
g()
g(value=1)
```

`x~` is a required labeled parameter. `x?` is an optional labeled parameter;
inside the function body it is bound as `Option[T]`. Default values in parameter
lists are not part of the current surface syntax.

### Type Aliases

```vibe
type Pair = (Int, Int)
export type IntResult = Result[Int, String]
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

```vibe
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

## Expressions

### Blocks

```vibe
{
  let x = 1
  let y = 2
  x + y
}
```

### Control Flow

```vibe
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
- `break Expr` returns a value from `loop` / `while`. `break(acc)` is parsed as
  `break` followed by a parenthesized expression -- NOT the same shape as
  `continue(a, b)`'s call-like next-state argument list. `break(a, b)` builds
  the tuple `(a, b)`, it does not break with two separate loop-result values
  (see `docs/tutorial/02_control_flow.vibe.md`'s loop section for a runnable
  example of this asymmetry).
- Parameterized `loop (...)` is tail-recursive state threading.
- Avoid naming a top-level function `f` or `g`: those identifiers collide
  with `@vibe/prelude/func.vibe`'s `compose`/`flip` combinator parameter
  names and can produce invalid wasm at codegen time (checker passes,
  `vibe run` fails to instantiate) -- tracked in #1203. Not a general
  language ambiguity, just a known name-collision gap in the current
  codegen; use any other identifier.

### Calls, Fields, Indexing

```vibe
f(x)
f(x=1, y=2)
Array::map(xs, _ * 2)
point.x
tuple.0
arr[0]
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

### Collections

```vibe
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

```vibe
throw("message")
risky()?

perform Logger::Log("hello")

handle { risky() } with Error {
  Throw(msg) => -1
}

handle { greet("world") } with Logger {
  Log(msg) => {
    resume(())
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

```vibe
x = value
x += 1
x -= 1
x *= 2
x /= 2
x %= 2
```

## Pipe

```vibe
x |> f
x |> f(a, b)
x |> f |> g
arr |> Array::length
```

`lhs |> rhs(args...)` desugars to `rhs(lhs, args...)`.

## Patterns

```vibe
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

```vibe
match x {
  v if v > 0 => v,
  _ => 0,
}
```

Destructuring:

```vibe
let (a, b) = pair
let record { x, y } = rec
let Some(v) = opt else { fallback }
if opt is Some(v) { v } else { 0 }
```

## Types

```vibe
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
Result[T, E]
(Int, String)
(Int, String) -> Bool
() -> Int with { Error }
[T](T) -> T
[T: Eq + Ord](T) -> Bool
```

Rules:

- `i32`, `f32`, and `f64` are aliases for `Int`, `Float`, and `Double` in type
  positions.
- Function effects appear after return type: `-> T with { Effect }`.
- Effect row variables such as `with { e }` are accepted in polymorphic
  higher-order signatures.

## Tests And Benches

```vibe
test "arithmetic" {
  assert_eq(1 + 1, 2)
}

test smoke_case {
  assert(true)
}

bench "hot path" {
  expensive()
}
```

Quoted and bare test names are accepted. Quoted names are preferred in public
examples.

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

# Syntax Reference

Tour-oriented syntax reference for the vibe language. The canonical surface
syntax spec is [`../spec/syntax.md`](../spec/syntax.md).

## Literals

| Kind | Examples | Notes |
|------|----------|-------|
| Int | `42`, `-5`, `0xFF`, `0x1A2B` | 62-bit tagged, range: -2^61 ~ 2^61-1 |
| Float | `1.5f`, `2.0f` | 32-bit, suffix `f` |
| Double | `3.14`, `1.0e-10` | 64-bit, default decimal |
| String | `"hello"`, `"a\nb"` | Escapes: `\n`, `\t`, `\\`, `\"` |
| String interp | `"x = \{expr}"` | Nested braces allowed; `\(expr)` removed in 0.3.0 |
| Multiline str | `#\| line1` + `#\| line2` | Leading `#\|` prefix |
| Char | `'a'`, `'\n'` | Int alias for char code |
| Bool | `true`, `false` | |
| Unit | `()` | |

## Operators (precedence high to low)

| Precedence | Operators | Assoc | Notes |
|-----------|-----------|-------|-------|
| 1 | `.`, `()`, `[]` | left | postfix: field, call, index |
| 2 | `-x`, `!x` | right | unary |
| 3 | `*`, `/`, `%` | left | |
| 4 | `+`, `-` | left | |
| 5 | `<<`, `>>` | left | arithmetic right shift |
| 6 | `&` | left | bitwise AND |
| 7 | `^` | left | bitwise XOR |
| 8 | `\|` (bitwise) | left | bitwise OR |
| 9 | `==`, `!=`, `<`, `<=`, `>`, `>=` | none | non-associative |
| 10 | `\|>` | left | pipe |
| 11 | `&&` | left | short-circuit |
| 12 | `\|\|` | left | short-circuit |

Assignment: `=`, `+=`, `-=`, `*=`, `/=`, `%=` (statements, not expressions).

## Declarations

### let / let rec / let mut

```vibe
let x = 42
let y: Int = 10

let rec fact: (Int) -> Int = (n) -> {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

let counter = {
  let mut value = 0
  value += 1
  value
}
```

### Functions

```vibe
// Top-level named functions: `fn` (#727, ADR-0064). Pure sugar for the
// `let rec` form; full annotations required; top-level only.
fn add(x: Int, y: Int) -> Int { x + y }
fn fact(n: Int) -> Int { if n < 2 { 1 } else { n * fact(n - 1) } }
fn identity[T](x: T) -> T { x }
fn risky() -> Int with { Error } { throw("fail") }
fn labeled(x~: Int, y~: Int) -> Int { x + y }
export fn doubled(x: Int) -> Int { x * 2 }

// Optional contract clause: parses, no semantics yet (ADR-0064 Phase E, #731)
fn clamp(x: Int, lo: Int, hi: Int) -> Int where {
  requires: lo <= hi,
  ensures: result >= lo,
} {
  if x < lo { lo } else if x > hi { hi } else x
}
```

```vibe
// let form: values, computed functions, higher-order returns
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let inc: (Int) -> Int = (x) -> { x + 1 }

// Generic
let identity: [T](T) -> T = (x) -> { x }

// With effect
let risky: () -> Int with { Error } = () -> { throw("fail") }

// With trait bounds
let show: [T: Show](T) -> T = (x) -> { x }

// Labeled arguments
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
let six = f(x = 1, y = 5)
```

### Lambda shorthand

```vibe
let xs = [1, 2, 3]

// Single param, arrow
let doubled = Array::map(xs, x -> x * 2)

// Multi param
let sum = Array::fold(xs, 0, (acc, x) -> acc + x)

// Block body (arrow + { ... })
let inced = Array::map(xs, (x) -> { x + 1 })

// Placeholder
let doubled2 = Array::map(xs, _ * 2)
let sum2 = Array::fold(xs, 0, _ + _)
```

### enum

```vibe
enum Option[T] {
  Some(T);
  None
}

enum Color { Red; Green; Blue } derive(Eq)
```

### struct

```vibe
struct Point { x: Int; y: Int } derive(Eq)

let p = Point::{ x: 1, y: 2 }
let px = p.x   // => 1
let sum = match p { Point::{ x, y } => x + y }
```

### type alias

```vibe
type Pair = (Int, Int)
type Ids = Array[Int]
type MaybeInt = Option[Int]
```

### trait / impl

```vibe
trait Eq
trait Ord: Eq
export open trait Show

impl Eq for Int
impl [T: Eq] Eq for Array[T]
```

### suberror

```vibe
suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

// Single constructor shorthand
suberror MyError(String)
```

## Expressions

### Block

```vibe
let v = {
  let x = 1
  let y = 2
  x + y      // last expression is the value
}
```

### if / else

<!-- doctest-skip: 未定義名 (cond / then_expr ...) を参照する構文提示の断片 -->
```vibe skip
if cond { then_expr } else { else_expr }
if a { 1 } else if b { 2 } else { 3 }
```

### match

<!-- doctest-skip: 未定義名 (value / v) を参照する構文提示の断片 -->
```vibe skip
match value {
  Some(x) => x,
  None => 0,
}

// Or-pattern
match v { 1 | 2 | 3 => true, _ => false }

// Guard
match v { x if x > 0 => "pos", _ => "neg" }
```

### Loops

<!-- doctest-skip: 未定義名 (cond / body / arr / done) を参照する構文提示の断片 -->
```vibe skip
// while
while cond { body }

// for-in (returns collected array)
for x in arr { x * 2 }
for i, x in arr { i + x }

// loop (parameterized, tail-recursive)
loop (i = 0, sum = 0) {
  if i >= 10 { break sum }
  else { continue(i + 1, sum + i) }
}

// infinite loop
loop { if done { break } }
```

### do block

`do` is reserved and is not part of the current surface syntax.

### Pipe operator

<!-- doctest-skip: 未定義名 (x / f / g) を参照する構文提示の断片 -->
```vibe skip
x |> f          // f(x)
x |> f(a)       // f(x, a)
x |> f |> g     // g(f(x))
```

### Pipe-first call style

<!-- doctest-skip: 未定義名 (arr / s / point) を参照する構文提示の断片 -->
```vibe skip
arr |> Array::length
s |> String::substring(0, 5)

// value.field is field access only
point.x
```

### Tuple / Array / Record / Map

<!-- doctest-skip: 未定義名 (x / y / value) を含むリテラル構文の列挙 -->
```vibe skip
(1, "two", true)       // tuple
[1, 2, 3]              // array
record { x: 1, y: 2 }  // record
record { x, y }         // shorthand (x: x, y: y)
Map::from_pairs([("key", value)])  // string-keyed map (#960: literal removed)
```

### Index

<!-- doctest-skip: 未定義名 (arr / m / value) を参照する構文提示の断片 -->
```vibe skip
arr[0]           // array index (=> __index(arr, 0))
m["key"]         // map index
arr[0] = value   // index assignment
```

### Tuple index

```vibe
let t = (1, "two")
let t0 = t.0   // => 1
let t1 = t.1   // => "two"
```

## Patterns

| Pattern | Example | Notes |
|---------|---------|-------|
| Wildcard | `_` | Matches anything |
| Binding | `x` | Binds to variable |
| Int literal | `42` | |
| String literal | `"hello"` | |
| Bool literal | `true` | |
| Constructor | `Some(x)` | Enum variant |
| Tuple | `(a, b)` | |
| Record | `record { x, y }` | |
| Struct | `Point::{ x, y }` | |
| Or | `A \| B` | |
| Guard | `x if x > 0` | Only in match arms |

### Destructuring let

<!-- doctest-skip: 未定義名 (r / opt / fallback) の断片。record destructure は top-level では parse error (#830)、let-else の else は diverging 必須 -->
```vibe skip
let (a, b) = (1, 2)
let record { x, y } = r          // fn/test body 内で使う (#830)
let Some(v) = opt else { fallback }
```

## Type Annotations

<!-- doctest-skip: 型構文の列挙 (プログラムではない) -->
```vibe skip
// Primitives
Int, Float, Double, Bool, Char, String, Unit

// WASM aliases
i32, f32, f64

// Collections
Array[T], Map[K, V]
ArrayBuilder[T], MapBuilder[K, V]

// Generic (Option is the only built-in two-track type; #1324 removed Result,
// so a two-track return type is an ordinary user enum you declare yourself)
Option[T]

// Function type
(Int, String) -> Bool
() -> Int with { Error }

// Tuple type
(Int, String, Bool)

// Type variable
T, U, V

// Bounded
[T: Show]
[T: Eq + Ord]
```

## Effects

<!-- doctest-skip: `...` ellipsis + effect context 無しの top-level perform を含む構文提示の断片 -->
```vibe skip
// Row-first core flow: failure lives in the effect row, so the success value
// flows straight through and stages chain by ordinary application (#1324)
let parse_id: (String) -> Int with { Exception[String] } = (raw) -> { ... }
let load_user: (Int) -> String with { Exception[String] } = (id) -> { ... }

raw |> parse_id |> load_user

// Error boundary
let f: () -> Int with { Error } = () -> { throw("fail") }
handle { f() } with Error { Throw(msg) => -1 }

// User-defined effect
effect Ask { Question(Int) -> Int }
perform Ask::Question(42)
handle { perform Ask::Question(1) } with Ask { Question(v) => resume(v + 1) }

// Effect polymorphism
let apply: [T](f: (T) -> T with { e }, x: T) -> T with { e } = (f, x) -> {
  f(x)
}
```

## Qualified Names

Identifiers in vibe can contain special characters depending on context. The rules are:

### Package references with `@`

A `@` prefix introduces a package reference. After `@`, hyphens (`-`) and slashes (`/`) become part of the identifier (they are not treated as operators).

<!-- doctest-skip: package 参照構文の列挙 (単体では未解決名) -->
```vibe skip
@json                 // package "json"
@lib/path             // package "lib/path"
@my-utils/helpers     // package "my-utils/helpers"
```

Without `@`, a hyphen is the subtraction operator:

<!-- doctest-skip: 未定義名 (x / y / @my-pkg) を参照する構文提示の断片 -->
```vibe skip
x - y                 // subtraction
@my-pkg               // identifier "my-pkg" (hyphen is part of the name)
```

### Member access with `.`

Dots are used for field access on values:

<!-- doctest-skip: 未定義名 (point / tuple / s) を参照する構文提示の断片 -->
```vibe skip
point.x               // field access
tuple.0               // tuple index
s.length              // field access
```

Dots are **not** part of a bare identifier. They are always parsed as the member access operator (precedence 1).

### Type/module member access with `::`

Double colons are used to access members of types or modules:

<!-- doctest-skip: qualified name の列挙 (呼び出し文脈なしの bare 参照は未解決) -->
```vibe skip
Array::length          // type method
Option::Some           // enum constructor
String::substring      // type method
MyModule::x            // module member
Point::{ x: 1, y: 2 } // struct literal
```

### Summary table

| Syntax | Meaning | Example |
|--------|---------|---------|
| `@name` | Package reference | `@json`, `@lib/path` |
| `-` after `@` | Part of package name | `@my-pkg` |
| `/` after `@` | Part of package path | `@lib/path` |
| `-` without `@` | Subtraction operator | `x - 1` |
| `.` | Field/member access | `point.x` |
| `::` | Type/module member | `Array::length` |

## Module System

### export

```vibe
export let f: (Int) -> Int = (x) -> { x + 1 }
export enum Color { Red; Green; Blue }
export { name1, name2 }
```

### import

<!-- doctest-skip: 存在しない import 先 (./lib.vibe) を参照する構文一覧 (#831) -->
```vibe skip
import ./lib.vibe { func1, func2 }
import ./lib.vibe { func1 as renamed }
import ./lib.vibe { type MyType, trait Show }
```

### module (removed)

`module Name { ... }` blocks are **removed** (#728, ADR-0063). Use file
boundaries + import/export. `Type::method` / `Effect::Op` qualified access
is an independent mechanism and remains.

## Test and Bench

```vibe
let expensive_computation: () -> Int = () -> { 42 }

test "name" {
  assert(eq(1 + 1, 2))
  assert(String::equals("a", "a"))
  assert_eq(42, 42)
}

bench "name" {
  expensive_computation()
}
```

## Keywords

`let`, `rec`, `fn` (statement head only), `mut`, `if`, `else`, `match`, `do`, `while`, `loop`, `for`, `in`,
`break`, `continue`, `yield`, `throw`, `perform`, `resume`, `handle`,
`test`, `bench`, `enum`, `struct`, `trait`, `impl`, `type`, `import`,
`export`, `internal`, `extern`, `as`, `true`, `false`, `suberror`,
`derive`

`record` and `map` are context-sensitive literal heads. `map` is not a reserved
keyword.

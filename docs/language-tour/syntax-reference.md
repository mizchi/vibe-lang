# Syntax Reference

Complete syntax reference for the vibe language.

## Literals

| Kind | Examples | Notes |
|------|----------|-------|
| Int | `42`, `-5`, `0xFF`, `0x1A2B` | 62-bit tagged, range: -2^61 ~ 2^61-1 |
| Float | `1.5f`, `2.0f` | 32-bit, suffix `f` |
| Double | `3.14`, `1.0e-10` | 64-bit, default decimal |
| String | `"hello"`, `"a\nb"` | Escapes: `\n`, `\t`, `\\`, `\"` |
| String interp | `"x = \(expr)"` | Nested parens allowed |
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

let rec fact = (n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

let mut counter = 0
counter += 1
```

### Functions

```vibe
// Named with types
let add = (x: Int, y: Int) -> Int { x + y }

// Inferred return type
let inc = (x: Int) { x + 1 }

// Generic
let identity = [T](x: T) -> T { x }

// With effect
let risky = () -> Int with { Error } { throw("fail") }

// With trait bounds
let show = [T: Show](x: T) -> String { to_string(x) }

// Labeled arguments
let f = (x: Int, y~: String, z?: Int = 0) -> Int { x + z }
f(1, y = "ok", z = 5)
```

### Lambda shorthand

```vibe
// Single param, arrow
array_map(xs, x -> x * 2)

// Multi param
array_fold(xs, 0, (acc, x) -> acc + x)

// Block body
array_map(xs, (x) { x + 1 })

// Placeholder
array_map(xs, _ * 2)
array_fold(xs, 0, _ + _)
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
p.x   // => 1
match p { Point::{ x, y } => x + y }
```

### type alias

```vibe
type Pair = (Int, Int)
type IntResult = Result[Int]
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
{
  let x = 1
  let y = 2
  x + y      // last expression is the value
}
```

### if / else

```vibe
if cond { then_expr } else { else_expr }
if a { 1 } else if b { 2 } else { 3 }
```

### match

```vibe
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

```vibe
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

```vibe
// Enables mutable builders and effectful builtins
do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_freeze(b)
}
```

### Pipe operator

```vibe
x |> f          // f(x)
x |> f(a)       // f(x, a)
x |> f |> g     // g(f(x))
```

### Method syntax

```vibe
// value.method(args) => method(value, args)
arr.array_length()
s.string_substring(0, 5)

// value.field => field(value)
point.x
```

### Tuple / Array / Record / Map

```vibe
(1, "two", true)       // tuple
[1, 2, 3]              // array
record { x: 1, y: 2 }  // record
record { x, y }         // shorthand (x: x, y: y)
map { "key": value }    // string-keyed map
```

### Index

```vibe
arr[0]           // array index (=> __index(arr, 0))
m["key"]         // map index
arr[0] = value   // index assignment
```

### Tuple index

```vibe
let t = (1, "two")
t.0   // => 1
t.1   // => "two"
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

```vibe
let (a, b) = (1, 2)
let record { x, y } = r
let Some(v) = opt else { fallback }
```

## Type Annotations

```vibe
// Primitives
Int, Float, Double, Bool, Char, String, Unit

// WASM aliases
i32, f32, f64

// Collections
Array[T], Map[V]
ArrayBuilder[T], MapBuilder[V]

// Generic
Option[T], Result[T]

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

```vibe
// Declare
let f = () -> Int with { Error } { throw("fail") }

// Handle
handle { f() } { Error(msg) => -1 }

// User-defined effect
enum Ask { Ask(Int) }
perform(Ask(42))
handle { perform(Ask(1)) } { Ask(v) => resume(v + 1) }

// Effect polymorphism
let apply = [T](f: (T) -> T with { e }, x: T) -> T with { e } { f(x) }
```

## Module System

### export

```vibe
export let f = (x: Int) -> Int { x + 1 }
export enum Color { Red; Green; Blue }
export { name1, name2 }
```

### import

```vibe
import ./lib.vibe { func1, func2 }
import ./lib.vibe { func1 as renamed }
import ./lib.vibe { type MyType, trait Show }
```

### module

```vibe
module MyModule {
  let x = 5
}

// Access: MyModule::x
```

## Test and Bench

```vibe
test "name" {
  assert(eq(1 + 1, 2))
  assert(string_equals("a", "a"))
  assert_eq(42, 42)
}

bench "name" {
  expensive_computation()
}
```

## Keywords

`let`, `rec`, `mut`, `if`, `else`, `match`, `do`, `while`, `loop`, `for`, `in`,
`break`, `continue`, `yield`, `throw`, `perform`, `resume`, `handle`,
`test`, `bench`, `enum`, `struct`, `trait`, `impl`, `type`, `import`,
`export`, `internal`, `extern`, `module`, `fn`, `as`, `true`, `false`, `record`, `map`,
`suberror`, `derive`

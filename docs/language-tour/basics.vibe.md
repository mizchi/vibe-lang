# Basics

## Types

| Type | Description | Example |
|------|-------------|---------|
| `Int` | 62-bit tagged integer | `42`, `0xFF` |
| `String` | UTF-16 string | `"hello"` |
| `Bool` | Boolean | `true`, `false` |
| `Float` | 32-bit float | `1.5f` |
| `Double` | 64-bit float | `3.14` |
| `Char` | Character (Int alias) | `'a'` |
| `Unit` | No value | `()` |

WASM aliases: `i32` = `Int`, `f32` = `Float`, `f64` = `Double`.

### Float / Double

```vibe
// Float (f32): suffix f
let x: Float = 1.5f
let y = 2.5f
let sum = x + y                    // => 4.0f

// Double (f64): default decimal literal
let d = 3.14
let fl = Double::floor(d)          // => 3.0
let ce = Double::ceil(d)           // => 4.0
let ab = Double::abs(-2.5)         // => 2.5

// Conversion
let td = Int::to_double(3)         // => 3.0
let ti = Double::to_int(3.14)      // => 3
let tf = Int::to_float(5)          // => 5.0f
let fd = Float::to_double(1.5f)    // => 1.5
```

## Variables

```vibe
let x = 1
let y: Int = 2

// Mutable
let count = {
  let mut value = 0
  value += 1
  value -= 1
  value *= 2
  value /= 2
  value %= 3
  value
}
```

## Functions

```vibe
// Named function
let inc: (Int) -> Int = (x) -> { x + 1 }

// Multi-param
let add: (Int, Int) -> Int = (x, y) -> { x + y }

// Recursive
let rec fact: (Int) -> Int = (n) -> {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

// Lambda — used inside functions or tests
// Array::map([1, 2, 3], (x) -> { x * 2 })
// Array::fold([1, 2, 3], 0, (acc, x) -> { acc + x })

// Short lambda / placeholder (may need explicit types)
// Array::map([1, 2, 3], x -> x * 2)
// Array::map([1, 2, 3], _ * 2)
// Array::fold([1, 2, 3], 0, _ + _)
```

## Generics

```vibe
let identity: [T](T) -> T = (x) -> { x }
let make_pair: [A, B](A, B) -> (A, B) = (a, b) -> { (a, b) }
let swap: [A, B](A, B) -> (B, A) = (a, b) -> { (b, a) }
```

## Labeled Arguments

```vibe
// y~ : required labeled argument (caller must use y = ...)
// z? : optional argument (receives Option[T])
let f: (Int, y~: String, z?: Int) -> String = (x, y~, z?) -> {
  let suffix = match z { Some(v) => Int::to_string(v), None => "none" }
  "\{y}-\{suffix}"
}
// f(1, y = "ok")          => "ok-none"
// f(1, y = "ok", z = 10)  => "ok-10"

let g: (Int, y?: Int) -> Int = (x, y?) -> {
  match y {
    Some(v) => x + v,
    None => x,
  }
}
// g(1)         => 1
// g(1, y = 5)  => 6
```

## Control Flow

### if/else (expression)

```vibe
let v = if true { 1 } else { 2 }
```

### while

```vibe
let total = {
  let mut i = 0
  let mut sum = 0
  while i <= 4 {
    sum += i
    i += 1
  }
  sum
}
// => 10
```

### for-in

```vibe
// Returns collected array
let tens = for x in [1, 2, 3] { x * 10 }
// => [10, 20, 30]

// With index
let with_index = for i, x in [10, 20, 30] { i + x }
// => [10, 21, 32]

// break / continue
let until4 = for x in [1, 2, 3, 4, 5] {
  if x == 4 { break } else { }
  x * 10
}
// => [10, 20, 30]
```

### loop (parameterized)

```vibe
let total = loop (i = 10, acc = 0) {
  if i <= 0 { break acc } else { continue(i - 1, acc + i) }
}
// => 55
```

### match

```vibe
// Enum
let from_enum = match Some(1) {
  Some(v) => v,
  None => 0,
}

// Tuple
let from_tuple = match (1, 2) {
  (a, b) => a + b,
  _ => 0
}

// Guard
let guarded = match 1 {
  v if v < 2 => 1,
  _ => 0
}

// Or-pattern
let small = match 2 {
  1 | 2 | 3 => true,
  _ => false
}

// Literal (Int, String, Bool, Float, Double)
let ok_flag = match "ok" {
  "ok" => 1,
  _ => 0
}
```

### do block

`do` is reserved and is not part of the current surface syntax. Use `for-in`
when you want a collected array expression:

```vibe
let built = for x in [1, 2] { x }
```

## String Interpolation

```vibe
let name = "vibe"
let msg = "hello \{name}"        // => "hello vibe"
let sum = "result: \{add(1, 2)}" // => "result: 3"
```

## Pipe Operator

```vibe
// Pipe inserts the left value as the first argument
// 1 |> add(2)          => add(1, 2)
// "hello" |> String::length  => String::length("hello")

let nine = 1 |> add(2) |> mul(3)   // => 9
```

## Type Definitions

### type alias

```vibe
type Pair = (Int, Int)
type IntResult = Result[Int, String]
```

### enum

```vibe
enum Result[T, E] {
  Ok(T);
  Err(E)
}

enum Color {
  Red;
  Green;
  Blue
}
```

### struct

```vibe
struct Point {
  x: Int; y: Int
}

let p = Point::{ x: 3, y: 4 }
let px = p.x  // => 3

// Pattern match
let sum = match p {
  Point::{ x, y } => x + y,
  _ => 0
}
```

### derive

```vibe
// Auto-derive Eq for enum
enum Color {
  Red;
  Green;
  Blue
} derive(Eq)

let same = eq(Red, Red)      // => true
let diff = eq(Red, Blue)     // => false

// Works with payload variants
enum Shape {
  Circle(Int);
  Rect(Int, Int)
} derive(Eq)

let c_eq = eq(Circle(5), Circle(5))   // => true
let c_ne = eq(Circle(5), Rect(1, 2))  // => false

// Also works for structs
struct Point {
  x: Int; y: Int
} derive(Eq)

let p_eq = eq(Point::{ x: 1, y: 2 }, Point::{ x: 1, y: 2 })  // => true
```

### trait / impl

```vibe
trait Eq
trait Show
trait Ord: Eq          // supertrait

impl Eq for Int
impl Show for Int
impl [T: Eq] Eq for Array[T]

// Trait bounds in functions
let f: [T: Eq](T) -> T = (x) -> { x }
let g: [T: Eq + Show](T) -> T = (x) -> { x }

// Inline trait bound
let h: [T: Eq](T) -> T = (x) -> { x }
```

## Option[T]

Built-in enum for optional values. Returned by `Array::find`, optional labeled arguments, etc.

```vibe
// Construction
let x = Some(42)
let y = None

// Pattern match
let value = match x {
  Some(v) => v,
  None => 0,
}
// => 42

// Common usage: Array::find
let found = match Array::find([1, 2, 3], (x) -> { x > 1 }) {
  Some(v) => v,    // => 2
  None => -1,
}
```

## Effects

Functions declare required effects with `with { ... }`.

```vibe
// sh / sh_lines require the Process effect; sh returns the captured
// output (String), so discard it explicitly in a Unit function
let run: () -> Unit with { Process } = () -> {
  let _ = sh("echo hello")
}
```

### Error handling

```vibe
// stub stages so the example is self-contained
fn parse_id(raw: String) -> Int with { Exception[String] } { 1 }
fn validate_id(id: Int) -> Int with { Exception[String] } { id }
fn load_user(id: Int) -> Int with { Exception[String] } { id }

fn fetch_user(raw: String) -> Int with { Exception[String] } {
  raw |> parse_id |> validate_id |> load_user
}

// Boundary helper when you need local Error handling
let safe_div: (Int, Int) -> Int with { Error } = (a, b) -> {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let result = handle { safe_div(8, 0) } with Error { Throw(_) => -1 }
// => -1
```

### Effect row variable

Effect-polymorphic functions propagate callee effects via `{ e }`.

```vibe
let apply: [T, U]((T) -> U with { e }, T) -> U with { e } = (f, x) -> {
  f(x)
}

test "effect row" {
  assert(eq(apply((x) -> { x + 1 }, 41), 42))
}
```

### suberror

Define typed error subtypes for structured error handling.

```vibe
suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

let risky: () -> Int with { Error } = () -> {
  throw(NotFound("missing"))
}

// #1324: the failure rides the row; the boundary is a `handle` at the edge.
fn lookup_user(raw: String) -> String with { Exception[AppError] } {
  if raw == "" { throw(NotFound("missing")) } else { raw }
}

let result = handle { lookup_user("42") } with Error { Throw(_) => "guest" }

let fallback = handle { risky() } with Error { Throw(_) => -1 }
// => -1
```

### perform / resume (algebraic effects)

User-defined effects via `effect` + `perform`/`resume`.

```vibe
effect Ask {
  Question(Int) -> Int
}

let ask_once: () -> Int with { Ask } = () -> {
  perform Ask::Question(41)
}

let result = handle {
  add(1, ask_once())
} with Ask {
  Question(v) => resume(add(v, 1))
}
// => 43
```

### async (experimental)

Requires `--unstable-async` flag.

<!-- doctest-skip: `yield` は現行 build path 未サポート (--unstable-async gated の experimental 例) -->
```vibe skip
let delayed: () -> Int with { Async } = () -> {
  yield
  42
}
```

## Module System

### export

```vibe
// math.vibe
export let double: (Int) -> Int = (x) -> { x * 2 }
```

### import

<!-- doctest-skip: 対になる math.vibe が実ファイルとして存在しない 2 ファイル例 (#831: 欠落 import は raw crash) -->
```vibe skip
// main.vibe
import ./math.vibe { double }

test "import" {
  assert(eq(double(5), 10))
}
```

Selective imports: `import ./file.vibe { name1, name2 }`.

## Tests

```vibe
test "example" {
  assert(eq(1 + 1, 2))
  assert(String::equals("a", "a"))
}
```

## Block Expression

```vibe
let value = {
  let base = 40
  base + 2
}
// => 42
```

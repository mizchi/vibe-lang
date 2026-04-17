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
x + y  // => 4.0f

// Double (f64): default decimal literal
let d = 3.14
Double::floor(d)  // => 3.0
Double::ceil(d)   // => 4.0
Double::abs(-2.5) // => 2.5

// Conversion
Int::to_double(3)     // => 3.0
Double::to_int(3.14)  // => 3
Int::to_float(5)      // => 5.0f
Float::to_double(1.5f) // => 1.5
```

## Variables

```vibe
let x = 1
let y: Int = 2

// Mutable
let mut count = 0
count += 1
count -= 1
count *= 2
count /= 2
count %= 3
```

## Functions

```vibe
// Named function
let inc = (x: Int) -> Int { x + 1 }

// Omit return type
let inc2 = (x: Int) { x + 1 }

// Multi-param
let add = (x: Int, y: Int) -> Int { x + y }

// Recursive
let rec fact = (n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

// Lambda — used inside functions or tests
// Array::map([1, 2, 3], (x: Int) -> Int { x * 2 })
// Array::fold([1, 2, 3], 0, (acc: Int, x: Int) -> Int { acc + x })

// Short lambda / placeholder (may need explicit types)
// Array::map([1, 2, 3], x -> x * 2)
// Array::map([1, 2, 3], _ * 2)
// Array::fold([1, 2, 3], 0, _ + _)
```

## Generics

```vibe
let identity = [T](x: T) -> T { x }
let make_pair = [A, B](a: A, b: B) -> (A, B) { (a, b) }
let swap = [A, B](p: (A, B)) -> (B, A) { (p.1, p.0) }
```

## Labeled Arguments

```vibe
// y~ : required labeled argument (caller must use y = ...)
// z? : optional argument (receives Option[T])
let f = (x: Int, y~: String, z?: Int) -> String {
  let suffix = match z { Some(v) => to_string(v), None => "none" }
  "\(y)-\(suffix)"
}
// f(1, y = "ok")          => "ok-none"
// f(1, y = "ok", z = 10)  => "ok-10"

// Default value for optional
let g = (x: Int, y?: Int = 0) -> Int { x + y }
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
let mut i = 0
let mut sum = 0
while i <= 4 {
  sum += i
  i += 1
}
```

### for-in

```vibe
// Returns collected array
for x in [1, 2, 3] { x * 10 }
// => [10, 20, 30]

// With index
for i, x in [10, 20, 30] { i + x }
// => [10, 21, 32]

// break / continue
for x in [1, 2, 3, 4, 5] {
  if x == 4 { break } else { }
  x * 10
}
// => [10, 20, 30]
```

### loop (parameterized)

```vibe
loop (i = 10, acc = 0) {
  if i <= 0 { break acc } else { continue(i - 1, acc + i) }
}
// => 55
```

### match

```vibe
// Enum
match Ok(1) {
  Ok(v) => v,
  Err => 0,
}

// Tuple
match (1, 2) {
  (a, b) => a + b,
  _ => 0
}

// Guard
match 1 {
  v if v < 2 => 1,
  _ => 0
}

// Or-pattern
match 2 {
  1 | 2 | 3 => true,
  _ => false
}

// Literal (Int, String, Bool, Float, Double)
match "ok" {
  "ok" => 1,
  _ => 0
}
```

### do block

`do { ... }` creates a pure boundary for mutable builders. `for-in` loops
also work as a pure alternative:

```vibe
let built = do {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
}

// equivalent using for-in
let built2 = for x in [1, 2] { x }
```

## String Interpolation

```vibe
let name = "vibe"
let msg = "hello \(name)"        // => "hello vibe"
let sum = "result: \(add(1, 2))" // => "result: 3"
```

## Pipe Operator

```vibe
// Pipe inserts the left value as the first argument
// 1 |> add(2)          => add(1, 2)
// "hello" |> String::length  => String::length("hello")

1 |> add(2) |> mul(3)   // => 9
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
p.x  // => 3

// Pattern match
match p {
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

eq(Red, Red)     // => true
eq(Red, Blue)    // => false

// Works with payload variants
enum Shape {
  Circle(Int);
  Rect(Int, Int)
} derive(Eq)

eq(Circle(5), Circle(5))  // => true
eq(Circle(5), Rect(1, 2)) // => false

// Also works for structs
struct Point {
  x: Int; y: Int
} derive(Eq)

eq(Point::{ x: 1, y: 2 }, Point::{ x: 1, y: 2 })  // => true
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
let f = [T: Eq](x: T) -> T { x }
let g = [T: Eq + Show](x: T) -> T { x }

// Inline trait bound
let h = [T](x: T: Eq) -> T { x }
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
match Array::find([1, 2, 3], (x: Int) -> Bool { x > 1 }) {
  Some(v) => v,    // => 2
  None => -1,
}
```

## Effects

Functions declare required effects with `with { ... }`.

```vibe
let run = () -> Unit with { Stdout } {
  sh("echo hello")
}
```

### Error handling

```vibe
let parse_id = (raw: String) -> Result[Int, String] { ... }
let validate_id = (id: Int) -> Result[Int, String] { ... }
let load_user = (id: Int) -> Result[String, String] { ... }

let fetch_user = (raw: String) -> Result[String, String] {
  raw
  |> parse_id
  |> Result::and_then(validate_id)
  |> Result::and_then(load_user)
}

// Boundary helper when you need local Error handling
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let result = handle { safe_div(8, 0) } with Error { Throw(_) => -1 }
// => -1
```

### Effect row variable

Effect-polymorphic functions propagate callee effects via `{ e }`.

```vibe
let apply = [T, U](f: (T) -> U with { e }, x: T) -> U with { e } { f(x) }

test "effect row" {
  assert(eq(apply((x: Int) -> Int { x + 1 }, 41), 42))
}
```

### suberror

Define typed error subtypes for structured error handling.

```vibe
suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

let risky = () -> Int with { Error } {
  throw(NotFound("missing"))
}

let lookup_user = (raw: String) -> Result[String, AppError] {
  if raw == "" { Err(NotFound("missing")) } else { Ok(raw) }
}

let result = match lookup_user("42") {
  Ok(user) => user,
  Err(_) => "guest"
}

let fallback = handle { risky() } with Error { Throw(_) => -1 }
// => -1
```

### perform / resume (algebraic effects)

User-defined effects via enum + `perform`/`resume`.

```vibe
enum Eff {
  Ask(Int)
}

let ask_once = () -> Int with { Ask } {
  perform(Ask(41))
}

let result = handle {
  add(1, ask_once())
} with Ask {
  Ask(v) => resume(add(v, 1))
}
// => 43
```

### async (experimental)

Requires `--unstable-async` flag.

```vibe
let delayed = () -> Int with { Async } {
  yield
  42
}
```

## Module System

### export

```vibe
// math.vibe
export let double = (x: Int) -> Int { x * 2 }
```

### import

```vibe
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

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
double_floor(d)  // => 3.0
double_ceil(d)   // => 4.0
double_abs(-2.5) // => 2.5

// Conversion
int_to_double(3)     // => 3.0
double_to_int(3.14)  // => 3
int_to_float(5)      // => 5.0f
float_to_double(1.5f) // => 1.5
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

// Lambda (single param, arrow)
array_map([1, 2, 3], x -> x * 2)

// Lambda (multi param)
array_fold([1, 2, 3], 0, (acc, x) -> acc + x)

// Lambda (block body)
array_map([1, 2, 3], (x) { x + 1 })

// Placeholder shorthand
array_map([1, 2, 3], _ * 2)
array_fold([1, 2, 3], 0, _ + _)
array_map([1, 2, 3], add(_, 10))
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
f(1, y = "ok")          // => "ok-none"
f(1, y = "ok", z = 10)  // => "ok-10"

// Default value for optional
let g = (x: Int, y?: Int = 0) -> Int { x + y }
g(1)         // => 1
g(1, y = 5)  // => 6
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

`do { ... }` creates an effect-allowed context for mutable builders and IO.

```vibe
let built = do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_push(b, 2)
  array_builder_freeze(b)
}
```

## String Interpolation

```vibe
let name = "vibe"
let msg = "hello \(name)"        // => "hello vibe"
let sum = "result: \(add(1, 2))" // => "result: 3"
```

## Pipe Operator

```vibe
let result = 1 |> add(2) |> mul(3)   // => 9
let len = "hello" |> string_length   // => 5
```

## Method Syntax

```vibe
// value.method(args) desugars to method(value, args)
let s = "hello world"
let sub = s.string_substring(0, 5)
sub.string_length()  // => 5
```

## Type Definitions

### type alias

```vibe
type Pair = (Int, Int)
type IntResult = Result[Int]
```

### enum

```vibe
enum Result[T] {
  Ok(T);
  Err
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

Built-in enum for optional values. Returned by `array_find`, optional labeled arguments, etc.

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

// Common usage: array_find
match array_find([1, 2, 3], (x: Int) -> Bool { x > 1 }) {
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
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

// Catch errors with handle
let result = handle { safe_div(8, 0) } { Error(_) => -1 }
// => -1
```

### Effect row variable

Effect-polymorphic functions propagate callee effects via `{ e }`.

```vibe
let apply = [T, U](f: (T) -> U with { e }, x: T) -> U with { e } { f(x) }
apply((x: Int) -> Int { x + 1 }, 41)  // => 42
```

### suberror

```vibe
suberror AppError {
  Io(String);
  Parse(Int);
}

let fail = () -> Unit with { Error } {
  throw(Io("io"))
}
```

## Tests

```vibe
test "example" {
  assert(eq(1 + 1, 2))
  assert(string_equals("a", "a"))
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

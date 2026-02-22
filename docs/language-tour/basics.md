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
let labeled = (x: Int, y~: String, z?: Bool) { y }
let result = labeled(1, y = "ok")
```

- `x~` -- required labeled argument
- `z?` -- optional (with or without default)

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

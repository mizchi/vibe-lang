# vibe Quick Start

ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.
For full details see [index.vibe.md](index.vibe.md).

## CLI

```bash
vibe run file.vibex   # Run executable root (executes `fn main`)
vibe test file.vibe   # Run tests in a file
vibe shell            # Interactive shell (PosixMode)
vibe check file.vibe  # Type check
```

## Entry Point

A `.vibex` executable root contains exactly one non-exported
`fn main with { ... } { ... }`. It takes no parameters, returns `Unit`, and its
closed effect row is explicit (`with { }` for a pure entry). The top level is
declarations-only, and statements/side effects go in `main`. A `.vibex` file
cannot be imported. When you `vibe build`, `main` is lowered to the generated
WASM `_start` ABI entry point.

```vibe
import ./lib/@vibe/prelude/io.vibe { stdout_write }

let add: (Int, Int) -> Int = (x, y) -> { x + y }

fn main with { Stdout } {
  stdout_write("add(1, 2) = \{add(1, 2)}\n")
}
```

## Basics

```vibe
// Variables
let x = 1
let count = {
  let mut value = 0
  value += 1
  value
}

// String interpolation
let name = "vibe"
let msg = "hello \{name}"

// Functions
let inc: (Int) -> Int = (x) -> { x + 1 }
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let rec fact: (Int) -> Int = (n) -> {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

// Generics
let identity: [T](T) -> T = (x) -> { x }

// Pipe — passes value as FIRST argument
// 1 |> add(2) |> mul(3)  => 9   (add(1,2) => mul(3,3))

// Pipe-first call style
// "hello" |> String::length  => 5
```

> **Pipe `|>` with HOFs**: The pipe operator inserts the left value as the
> first argument. All collection HOFs take the array as the first argument,
> so piping works naturally:
> ```vibe
> [1, 2, 3, 4, 5]
>   |> Array::filter((x) -> { x % 2 == 0 })
>   |> Array::fold(0, (acc, x) -> { acc + x })
> ```

## Types

`Int`, `String`, `Bool`, `Float` (`1.5f`), `Double` (`3.14`), `Unit` (`()`).

## Control Flow

```vibe
// if (expression)
let x = 1
let v = if x > 0 { "pos" } else { "neg" }

// for-in (returns collected array)
// for x in [1, 2, 3] { x * 10 }       => [10, 20, 30]
// for i, x in [10, 20, 30] { i + x }  => [10, 21, 32]

// while (returns Unit — use mut variable to collect results)
// while i < 10 { i += 1 }

// loop (parameterized)
// loop (i = 10, acc = 0) {
//   if i <= 0 { break acc } else { continue(i - 1, acc + i) }
// }

// match (enum — user-defined, not built-in)
enum MaybeInt { Hit(Int); Miss }
let result = match Hit(42) {
  Hit(v) => v,
  Miss => 0,
}
// guards: v if v < 2 => ...
// or-pattern: 1 | 2 | 3 => ...
// literal: match "ok" { "ok" => 1, _ => 0 }
```

## Type Definitions

```vibe
type Pair = (Int, Int)                       // alias
enum Result[T, E] { Ok(T); Err(E) }         // enum
struct Point { x: Int; y: Int }              // struct
let p = Point::{ x: 3, y: 4 }
trait Eq                                     // trait (declaration only)
impl Eq for Int                              // impl (declaration only)
```

> **Struct vs Record**: `struct` has a fixed schema with typed fields and uses
> `Point::{ x: 3, y: 4 }` syntax. `record` is a dynamic string-keyed object.
> They are **not interchangeable**.

## Collections

```vibe
// Array
let arr = [1, 2, 3]
// arr[0]                     => index access
// Array::length(arr)         => 3

// Map (string-keyed, all values must be same type)
let m = Map::from_pairs([("a", 1), ("b", 2)])
// Map::get(m, "a")           => 1
// Map::keys(m)               => ["a", "b"]

// Record (dynamic)
let r = record { x: 3, y: 4 }
// let record { x, y } = r  => destructure (fn/test body 内で使う; top-level は #830)

// Tuple
let pair = (1, "two")
// pair.0                    => 1
let (a, b) = pair         // destructure
```

## Effects & Error Handling

```vibe
// Preferred: carry the failure in the row (stub stages for a runnable example)
fn parse_id(raw: String) -> Int with { Exception[String] } { 1 }
fn load_user(id: Int) -> Int with { Exception[String] } { id }

fn run(raw: String) -> Int with { Exception[String] } {
  raw |> parse_id |> load_user
}

// Boundary helper when you need to localize Error
let safe_div: (Int, Int) -> Int with { Error } = (a, b) -> {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}
let result = handle { safe_div(8, 0) } with Error { Throw(_) => -1 }
// => -1
```

## Tests

```vibe
test "example" {
  assert(eq(1 + 1, 2))
  assert(String::equals("hello", "hello"))
  // Array operations in test blocks
  let doubled = Array::map([1, 2, 3], (x) -> { x * 2 })
  assert(eq(Array::length(doubled), 3))
}
```

> **Note**: Effects like `sh`/`sh_lines` work implicitly in test blocks.

## Key Builtins

**String**: `String::length`, `String::concat`, `String::substring`, `String::split`, `String::join`, `String::contains`, `String::trim`, `String::replace`, `String::replace_all`, `String::to_upper`, `String::to_lower`, `String::equals`

**Array**: `Array::length`, `Array::get`, `Array::slice`, `Array::concat`, `Array::reverse`, `Array::sort`, `Array::map`, `Array::filter`, `Array::fold`, `Array::any`, `Array::all`, `Array::find` (returns `Option[T]`), `Array::contains`, `Array::join`

**Map**: `Map::get`, `Map::get_or`, `Map::has_key`, `Map::keys`, `Map::values`, `Map::map`, `Map::filter`

**Conversion**: `to_string`, `Int::to_double`, `Double::to_int`, `Int::to_float`, `Float::to_int`

**Math**: `Int::abs`, `Int::max`, `Int::min`, `Double::floor`, `Double::ceil`

**IO**: `sh`, `sh_lines`, `Stdout::write_stream`, `Stdin::read_stream`

**JSON**: `Json::parse`, `Json::stringify`, `Json::get`, `Json::index`, `Json::string`, `Json::number`, `Json::bool`, `Json::type_of`, `Json::keys`, `Json::length`

Full reference: [builtins.md](builtins.md)

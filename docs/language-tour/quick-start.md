# vibe Quick Start

ML-like statically typed scripting language with shell integration, targeting WASM/wasip3.
For full details see [index.md](index.md).

## CLI

```bash
vibe run file.vibe    # Run script (requires `main` function)
vibe test file.vibe   # Run tests in a file
vibe shell            # Interactive REPL (PosixMode)
vibe check file.vibe  # Type check
```

## Basics

```vibe
// Variables
let x = 1
let mut count = 0
count += 1

// String interpolation
let name = "vibe"
let msg = "hello \(name)"

// Functions — parameter types are always required
let inc = (x: Int) -> Int { x + 1 }
let add = (x: Int, y: Int) -> Int { x + y }
let rec fact = (n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

// Lambda — use explicit types for reliable type inference
Array::map([1, 2, 3], (x: Int) -> Int { x * 2 })
Array::fold([1, 2, 3], 0, (acc: Int, x: Int) -> Int { acc + x })

// Short lambda / placeholder — MAY FAIL in REPL with type inference errors.
// Always prefer explicit types:
//   Array::map(arr, x -> x * 2)     -- may fail
//   Array::map(arr, _ * 2)          -- may fail
//   Array::map(arr, (x: Int) -> Int { x * 2 })  -- reliable

// Generics
let identity = [T](x: T) -> T { x }

// Pipe — passes value as FIRST argument
1 |> add(2) |> mul(3)  // => 9   (add(1,2) => mul(3,3))

// Pipe-first call style
"hello" |> String::length  // => 5
// Note: struct.field (e.g. p.x) is field access only
```

> **Pipe `|>` with HOFs**: The pipe operator inserts the left value as the
> first argument. All collection HOFs take the array as the first argument,
> so piping works naturally:
> ```vibe
> [1, 2, 3, 4, 5]
>   |> Array::filter((x: Int) -> Bool { x % 2 == 0 })
>   |> Array::fold(0, (acc: Int, x: Int) -> Int { acc + x })
> ```

## Types

`Int`, `String`, `Bool`, `Float` (`1.5f`), `Double` (`3.14`), `Unit` (`()`).

## Control Flow

```vibe
// if (expression)
let v = if x > 0 { "pos" } else { "neg" }

// for-in (returns collected array)
for x in [1, 2, 3] { x * 10 }       // => [10, 20, 30]
for i, x in [10, 20, 30] { i + x }  // => [10, 21, 32]

// while (returns Unit — use mut variable to collect results)
while i < 10 { i += 1 }

// loop (parameterized)
loop (i = 10, acc = 0) {
  if i <= 0 { break acc } else { continue(i - 1, acc + i) }
}

// match (enum — user-defined, not built-in)
enum MaybeInt { Hit(Int); Miss }
match Hit(42) {
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
enum Result[T] { Ok(T); Err }               // enum
struct Point { x: Int; y: Int }              // struct
let p = Point::{ x: 3, y: 4 }
trait Eq                                     // trait (declaration only)
impl Eq for Int                              // impl (declaration only)
```

> **Struct vs Record**: `struct` has a fixed schema with typed fields and uses
> `Point::{ x: 3, y: 4 }` syntax. `record` is a dynamic string-keyed object.
> They are **not interchangeable** — `record { }` destructuring does not work on
> structs, and struct types cannot be used as lambda type annotations in HOFs.
> For data processing with `Array::filter`/`Array::map`, prefer `record` or use
> `for` comprehensions with structs.

## Collections

```vibe
// Array
let arr = [1, 2, 3]
arr[0]                    // index
Array::length(arr)         // 3
Array::map(arr, (x: Int) -> Int { x * 2 })
Array::filter(arr, (x: Int) -> Bool { x > 1 })
Array::fold(arr, 0, (acc: Int, x: Int) -> Int { acc + x })
Array::concat([1, 2], [3, 4])

// Map (string-keyed, all values must be same type)
let m = map { a: 1, "b": 2 }
Map::get(m, "a")           // 1
Map::keys(m)               // ["a", "b"]

// Record (dynamic)
let r = record { x: 3, y: 4 }
let record { x, y } = r  // destructure

// Tuple
let pair = (1, "two")
pair.0                    // 1
let (a, b) = pair         // destructure
```

## JSON

```vibe
// Parse
let data = Json::parse("{\"name\": \"vibe\", \"version\": 1}")

// Object access
Json::get(data, "name")                   // => Json
Json::string(Json::get(data, "name"))      // => "vibe"
Json::number(Json::get(data, "version"))   // => 1 (returns Double)

// Array access — use Json::index for arrays, Json::get for objects
let arr = Json::parse("[10, 20, 30]")
Json::index(arr, 0)        // => Json(10)
Json::length(arr)          // => 3
Json::number(Json::index(arr, 1))  // => 20 (returns Double)

// Type check
Json::type_of(data)           // => "object"
Json::is_null(Json::parse("null"))  // => true
Json::keys(data)           // => ["name", "version"]

// Serialize (NOTE: Json::stringify may hang in REPL — use in .vibe files or tests)
// Json::stringify(42)            // => "42"

// JSON number → Int: Json::number returns Double, convert with Double::to_int
let age = Double::to_int(Json::number(Json::get(data, "version")))  // => 1

// CAUTION: Json::parse with invalid input causes a runtime error
// that cannot be caught by handle. Ensure input is valid JSON.
```

## Shell

`sh` and `sh_lines` require the `{Stdout}` effect. Use `do { ... }` to enable effects.

> **REPL Constraint**: In `vibe shell`, each input line is evaluated independently.
> Multi-line blocks (`do { ... }`, `for ... { ... }`) must be written on **one line**
> with semicolons: `do { sh("echo hi"); let x = 1; x }`.
> Multi-line syntax is only supported in `.vibe` files.

```vibe
// Wrap in do block — required even in REPL
// In REPL, the entire do block must be on ONE line (semicolon-separated):
do { sh("echo hello"); let files = sh_lines("ls src"); Array::length(files) }

// In a .vibe file, multi-line is fine:
// do {
//   sh("echo hello")
//   let files = sh_lines("ls src")
//   Array::length(files)
// }

// In a function — declare effects in signature
let run = () -> Unit with { Stdout } {
  sh("echo hello")
}

// In test blocks — effects are implicit
test "shell" {
  let lines = sh_lines("echo hello")
  assert(eq(Array::length(lines), 1))
}
```

### PosixMode (REPL)

In `vibe shell`, lines that start with a bare identifier are desugared to `sh_lines()`.

**Not desugared**: lines starting with keywords (`let`, `if`, `for`, `match`, etc.)
or expressions with parentheses/operators.

```
> ls /tmp
note: posix-mode command-head desugar: ls -> sh_lines("ls")

> let x = 1        # NOT desugared (starts with keyword)
> add(1, 2)        # NOT desugared (has parentheses)
```

> **Pitfall**: A bare variable name like `files` or `result` on its own line
> will be desugared to `sh_lines("files")`. Always use `let` bindings
> or wrap in an expression (e.g. `eq(x, x)`) to avoid this.

`{{ expr }}` embeds vibe expressions in PosixMode commands:

```
> echo result is {{ 1 + 2 }}
3
```

> **Note**: `{{ expr }}` works with inline expressions. Variables from previous REPL
> lines may not be accessible inside `{{ }}` due to scope limitations.

### REPL Output Format

```
cwd: /path/to/project              # session start (ignore)
namespace: scratch db=...          # session start (ignore)
last: 42                           # expression result
addr: x#a1b2c3d                    # let binding stored (ignore)
```

The evaluated result is on the `last:` line. `cwd:`, `namespace:`, and `addr:` lines are metadata.

## Effects & Error Handling

```vibe
// Error effect
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

// Catch with handle
let result = handle { safe_div(8, 0) } { Error(_) => -1 }
// => -1
```

> **Note**: `handle { ... } { Error(_) => ... }` catches errors from `throw()`.
> Runtime errors from builtins (e.g. `Json::parse` with invalid input) are **not**
> catchable by `handle` — they abort execution. Validate input before calling
> such functions.

## Tests

```vibe
test "example" {
  assert(eq(1 + 1, 2))
  assert(String::equals("hello", "hello"))
}
```

> **Note**: Both `assert_eq(a, b)` and `assert(eq(a, b))` work for
> numeric comparisons. For strings, use `assert(String::equals(a, b))`.
> Effects like `sh`/`sh_lines` work implicitly in test blocks (no `do { }` needed).

## Key Builtins

**String**: `String::length`, `String::concat`, `String::split`, `String::join`, `String::contains`, `String::substring`, `String::replace`, `String::replace_all`, `String::trim`, `String::to_upper`, `String::to_lower`, `String::equals`

```vibe
String::trim("  hello  ")                         // => "hello"
String::replace("hello world", "world", "vibe")   // => "hello vibe"
String::replace_all("aabaa", "a", "x")            // => "xxbxx"
String::substring("hello world", 0, 5)            // => "hello"
String::to_upper("hello")                         // => "HELLO"
String::to_lower("HELLO")                         // => "hello"
```

**Array**: `Array::length`, `Array::get`, `Array::slice`, `Array::concat`, `Array::reverse`, `Array::sort`, `Array::map`, `Array::filter`, `Array::fold`, `Array::any`, `Array::all`, `Array::find` (returns `Option[T]`), `Array::contains`, `Array::join`

> Most array HOFs are **generic** — they work with any element type (String, Bool, etc.),
> not just numbers. `Array::sort` and `Array::contains` require numeric types (`eq`/`lt`).

```vibe
// Array::any/all: collection is FIRST arg, predicate is LAST
Array::any([1, 2, 3, 4], (x: Int) -> Bool { x > 3 })   // => true
Array::all([1, 2, 3], (x: Int) -> Bool { x > 0 })       // => true
// Array::find: returns Option[T] — Some(value) or None
Array::find([1, 2, 3, 4, 5], (x: Int) -> Bool { x > 3 }) // => Some(4)
```

**Map**: `Map::get`, `Map::get_or`, `Map::has_key`, `Map::keys`, `Map::values`, `Map::map`, `Map::filter`

> **`Map::get` throws on missing key.** Use `Map::get_or` for safe access with a default.

```vibe
Map::get_or(map { a: 1, b: 2 }, "c", 0)  // => 0 (default)
Map::has_key(map { a: 1, b: 2 }, "a")    // => true
```

**Map Builder** (imperative map construction, requires `do { }` context):

```vibe
do { let b = MapBuilder::new(); MapBuilder::set(b, "x", 10); MapBuilder::freeze(b) }
```

**JSON**: `Json::parse`, `Json::stringify`, `Json::get`, `Json::index`, `Json::string`, `Json::number`, `Json::bool`, `Json::type_of`, `Json::keys`, `Json::length`, `Json::is_null`

**IO**: `sh`, `sh_lines`, `Stdout::write_stream`, `Stdin::read_stream`

**Math**: `Int::abs`, `Int::max`, `Int::min`, `Double::floor`, `Double::ceil`

```vibe
Int::abs(-5)        // => 5
Int::max(3, 7)      // => 7
```

**Conversion**: `Int::to_double`, `Double::to_int`, `Int::to_float`, `Float::to_int`, `to_string`

```vibe
to_string(42)       // => "42"
Double::to_int(3.14) // => 3
```

**Lines**: `Lines::parse` (split string by `\n` → `Array[String]`), `Lines::stringify` (join array with `\n`)

```vibe
Lines::parse("a\nb\nc")              // => ["a", "b", "c"]
Lines::stringify(["a", "b", "c"])          // => "a\nb\nc"
```

**Assert**: `assert(Bool)`, `assert_eq(a, b)`, `eq(a, b) -> Bool`

**Prelude**: `add`, `sub`, `mul`, `div`, `eq`, `lt`, `not`, `and`, `or`

Full reference: [builtins.md](builtins.md)

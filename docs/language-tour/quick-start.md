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
array_map([1, 2, 3], (x: Int) -> Int { x * 2 })
array_fold([1, 2, 3], 0, (acc: Int, x: Int) -> Int { acc + x })

// Short lambda / placeholder — MAY FAIL in REPL with type inference errors.
// Always prefer explicit types:
//   array_map(arr, x -> x * 2)     -- may fail
//   array_map(arr, _ * 2)          -- may fail
//   array_map(arr, (x: Int) -> Int { x * 2 })  -- reliable

// Generics
let identity = [T](x: T) -> T { x }

// Pipe — passes value as FIRST argument
1 |> add(2) |> mul(3)  // => 9   (add(1,2) => mul(3,3))

// Method syntax: value.method(args) => method(value, args)
"hello".string_length()  // => 5
// Note: struct.field (e.g. p.x) is field access, NOT method call
```

> **Pipe `|>` with HOFs**: The pipe operator inserts the left value as the
> first argument. All collection HOFs take the array as the first argument,
> so piping works naturally:
> ```vibe
> [1, 2, 3, 4, 5]
>   |> array_filter((x: Int) -> Bool { x % 2 == 0 })
>   |> array_fold(0, (acc: Int, x: Int) -> Int { acc + x })
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
> For data processing with `array_filter`/`array_map`, prefer `record` or use
> `for` comprehensions with structs.

## Collections

```vibe
// Array
let arr = [1, 2, 3]
arr[0]                    // index
array_length(arr)         // 3
array_map(arr, (x: Int) -> Int { x * 2 })
array_filter(arr, (x: Int) -> Bool { x > 1 })
array_fold(arr, 0, (acc: Int, x: Int) -> Int { acc + x })
array_concat([1, 2], [3, 4])

// Map (string-keyed, all values must be same type)
let m = map { a: 1, "b": 2 }
map_get(m, "a")           // 1
map_keys(m)               // ["a", "b"]

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
let data = from_json("{\"name\": \"vibe\", \"version\": 1}")

// Object access
json_get(data, "name")                   // => Json
json_string(json_get(data, "name"))      // => "vibe"
json_number(json_get(data, "version"))   // => 1 (returns Double)

// Array access — use json_index for arrays, json_get for objects
let arr = from_json("[10, 20, 30]")
json_index(arr, 0)        // => Json(10)
json_length(arr)          // => 3
json_number(json_index(arr, 1))  // => 20 (returns Double)

// Type check
json_type(data)           // => "object"
json_is_null(from_json("null"))  // => true
json_keys(data)           // => ["name", "version"]

// Serialize (NOTE: to_json may hang in REPL — use in .vibe files or tests)
// to_json(42)            // => "42"

// JSON number → Int: json_number returns Double, convert with double_to_int
let age = double_to_int(json_number(json_get(data, "version")))  // => 1

// CAUTION: from_json with invalid input causes a runtime error
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
do { sh("echo hello"); let files = sh_lines("ls src"); array_length(files) }

// In a .vibe file, multi-line is fine:
// do {
//   sh("echo hello")
//   let files = sh_lines("ls src")
//   array_length(files)
// }

// In a function — declare effects in signature
let run = () -> Unit with { Stdout } {
  sh("echo hello")
}

// In test blocks — effects are implicit
test "shell" {
  let lines = sh_lines("echo hello")
  assert(eq(array_length(lines), 1))
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
> Runtime errors from builtins (e.g. `from_json` with invalid input) are **not**
> catchable by `handle` — they abort execution. Validate input before calling
> such functions.

## Tests

```vibe
test "example" {
  assert(eq(1 + 1, 2))
  assert(string_equals("hello", "hello"))
}
```

> **Note**: Both `assert_eq(a, b)` and `assert(eq(a, b))` work for
> numeric comparisons. For strings, use `assert(string_equals(a, b))`.
> Effects like `sh`/`sh_lines` work implicitly in test blocks (no `do { }` needed).

## Key Builtins

**String**: `string_length`, `string_concat`, `string_split`, `string_join`, `string_contains`, `string_substring`, `string_replace`, `string_replace_all`, `string_trim`, `string_to_upper`, `string_to_lower`, `string_equals`

```vibe
string_trim("  hello  ")                         // => "hello"
string_replace("hello world", "world", "vibe")   // => "hello vibe"
string_replace_all("aabaa", "a", "x")            // => "xxbxx"
string_substring("hello world", 0, 5)            // => "hello"
string_to_upper("hello")                         // => "HELLO"
string_to_lower("HELLO")                         // => "hello"
```

**Array**: `array_length`, `array_get`, `array_slice`, `array_concat`, `array_reverse`, `array_sort`, `array_map`, `array_filter`, `array_fold`, `array_any`, `array_all`, `array_find` (returns `Option[T]`), `array_contains`, `array_join`

> Most array HOFs are **generic** — they work with any element type (String, Bool, etc.),
> not just numbers. `array_sort` and `array_contains` require numeric types (`eq`/`lt`).

```vibe
// array_any/all: collection is FIRST arg, predicate is LAST
array_any([1, 2, 3, 4], (x: Int) -> Bool { x > 3 })   // => true
array_all([1, 2, 3], (x: Int) -> Bool { x > 0 })       // => true
// array_find: returns Option[T] — Some(value) or None
array_find([1, 2, 3, 4, 5], (x: Int) -> Bool { x > 3 }) // => Some(4)
```

**Map**: `map_get`, `map_get_or`, `map_has_key`, `map_keys`, `map_values`, `map_map`, `map_filter`

> **`map_get` throws on missing key.** Use `map_get_or` for safe access with a default.

```vibe
map_get_or(map { a: 1, b: 2 }, "c", 0)  // => 0 (default)
map_has_key(map { a: 1, b: 2 }, "a")    // => true
```

**Map Builder** (imperative map construction, requires `do { }` context):

```vibe
do { let b = map_builder(); map_builder_set(b, "x", 10); map_builder_freeze(b) }
```

**JSON**: `from_json`, `to_json`, `json_get`, `json_index`, `json_string`, `json_number`, `json_bool`, `json_type`, `json_keys`, `json_length`, `json_is_null`

**IO**: `sh`, `sh_lines`, `stdout_write_stream`, `stdin_read_stream`

**Math**: `int_abs`, `int_max`, `int_min`, `double_floor`, `double_ceil`

```vibe
int_abs(-5)        // => 5
int_max(3, 7)      // => 7
```

**Conversion**: `int_to_double`, `double_to_int`, `int_to_float`, `float_to_int`, `to_string`

```vibe
to_string(42)       // => "42"
double_to_int(3.14) // => 3
```

**Lines**: `from_lines` (split string by `\n` → `Array[String]`), `to_lines` (join array with `\n`)

```vibe
from_lines("a\nb\nc")              // => ["a", "b", "c"]
to_lines(["a", "b", "c"])          // => "a\nb\nc"
```

**Assert**: `assert(Bool)`, `assert_eq(a, b)`, `eq(a, b) -> Bool`

**Prelude**: `add`, `sub`, `mul`, `div`, `eq`, `lt`, `not`, `and`, `or`

Full reference: [builtins.md](builtins.md)

# vibe Language Cheat Sheet

WASM-targeting, pure-by-default language with algebraic effects. Compiled via MoonBit toolchain.

## Quick Start

```vibe
let main: () -> Unit with { Stdout } = () -> {
  stdout_write("hello world\n")
}
```

```bash
vibe run hello.vibe        # compile & execute
vibe shell                 # interactive shell
vibe test file.vibe        # run tests
vibe check file.vibe       # type check only
vibe build --release app.vibe  # standalone .wasm
```

---

## Values & Types

```vibe
let x: Int = 42                // 62-bit tagged, max 2^61-1
let f: Float = 1.5f            // 32-bit (suffix f)
let d: Double = 3.14           // 64-bit (default decimal)
let s: String = "hello \(x)"  // interpolation with \(expr)
let c: Char = 'A'              // char code (Int alias)
let b: Bool = true
let u: Unit = ()
```

## Variables

```vibe
let x = 42            // immutable
let mut y = 0         // mutable (lexical scope only)
y += 1
```

## Functions

```vibe
// Preferred: type annotation separated from body
let add: (Int, Int) -> Int = (x, y) -> { x + y }
let inc: (Int) -> Int = (x) -> { x + 1 }
let rec fact: (Int) -> Int = (n) -> {     // recursive
  if n < 2 { 1 } else { n * fact(n - 1) }
}
let identity: [T](T) -> T = (x) -> { x }  // generic
let show: [T: Eq + Ord](T) -> T = (x) -> { x } // trait bounds
```

> **Deprecated**: `let f = (x: Int) -> Int { ... }` (inline param types)
> is deprecated. Use `vibe fmt` to auto-convert.

### Labeled arguments

```vibe
let f: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x + y }
f(x=10, y=20)
```

### Lambda shorthand

```vibe
Array::map(xs, x -> x * 2)
Array::map(xs, _ * 2)         // placeholder
Array::fold(xs, 0, _ + _)
```

## Operators (precedence: high to low)

| Prec | Operators | Notes |
|------|-----------|-------|
| 1 | `.` `()` `[]` | field, call, index |
| 2 | `-x` `!x` | unary |
| 3 | `*` `/` `%` | |
| 4 | `+` `-` | |
| 5 | `<<` `>>` | >> is arithmetic (sign-extending) |
| 6-8 | `&` `^` `\|` | bitwise AND, XOR, OR |
| 9 | `==` `!=` `<` `<=` `>` `>=` | non-assoc |
| 10 | `\|>` | pipe |
| 11-12 | `&&` `\|\|` | short-circuit (desugar to if) |

Assignment: `=` `+=` `-=` `*=` `/=` `%=` (statement, not expr)

## Pipe Operator

```vibe
x |> f            // f(x)
x |> f(a, b)      // f(x, a, b)
x |> f |> g       // g(f(x))
arr |> Array::length
s |> String::trim |> String::length
```

`.` is field access only. No method call sugar (`obj.method()` is error).

## Control Flow

```vibe
// if (expression)
let v = if cond { a } else { b }

// match
match opt {
  Some(x) if x > 0 => x,     // guard
  Some(_) => 0,
  None => -1,
}

// while
while cond { body }

// for-in (collects into array)
for x in arr { x * 2 }         // -> Array
for i, x in arr { i + x }      // with index

// loop (parameterized tail-recursion)
let mut result = 0
loop (i = 0, sum = 0) {
  if i >= 10 { result = sum; break }
  continue(i + 1, sum + i)
}
```

## Pattern Matching

```vibe
_                   // wildcard
x                   // binding
42, "hi", true      // literal
Some(x)             // constructor
(a, b, c)           // tuple
record { x, y }     // record
Point::{ x, y }     // struct
A | B               // or-pattern
x if x > 0          // guard (match arm only)
```

### Destructuring let

```vibe
let (a, b) = (1, 2)
let record { x, y } = r
let Some(v) = opt else { fallback }
```

### is expression

```vibe
if expr is Some(v) { use(v) }   // bind + test
expr is None                     // -> Bool
```

## Type Definitions

```vibe
type Pair = (Int, Int)                   // alias

enum Color { Red; Green; Blue } derive(Eq)
enum Shape { Circle(Int); Rect(Int, Int) }

struct Point { x: Int; y: Int } derive(Eq)
let p = Point::{ x: 1, y: 2 }
p.x                                       // field access

trait Eq
trait Ord: Eq                              // supertrait
export open trait Show                     // extensible outside module

impl Eq for Int
impl [T: Eq] Eq for Array[T]              // conditional impl
```

## Collections

```vibe
// Array
let a = [1, 2, 3]
a[0]                          // index
Array::length(a)
Array::map(a, _ * 2)            // r# escapes keyword

// Tuple
let t = (1, "two", true)
t.0                           // => 1

// Record
let r = record { name: "vibe", ver: 1 }
r.name

// Map
let m = map { "key": 42 }
m["key"]

// Builders (mutable construction)
let b = ArrayBuilder::new()
ArrayBuilder::push(b, 1)
ArrayBuilder::freeze(b)       // -> Array[Int]
```

## Effects (core concept)

vibe is **pure by default**. Side effects are tracked in the type system.

### Result-first pipeline (recommended)

```vibe
let parse_id: (String) -> Result[Int, String] = (raw) -> { ... }
let validate_id: (Int) -> Result[Int, String] = (id) -> { ... }
let load_user: (Int) -> Result[String, String] = (id) -> { ... }

let fetch_user: (String) -> Result[String, String] = (raw) -> {
  raw
  |> parse_id
  |> Result::and_then(validate_id)
  |> Result::and_then(load_user)
}
```

### Error boundary (`throw` / `handle`)

```vibe
let risky: (Int) -> Int with { Error } = (x) -> {
  if x == 0 { throw("division by zero") }
  100 / x
}

// handle catches the effect
let safe = handle { risky(0) } with Error { Throw(msg) => -1 }

// ? operator (sugar for handle + rethrow)
let result = risky(n)?
```

### suberror (typed errors)

```vibe
suberror NotFound(String)
suberror InvalidInput(Int, String)   // tuple payload only
```

### User-defined effects (algebraic)

```vibe
effect Logger {
  Log(String) -> Unit
}

let greet: (String) -> Unit with { Logger } = (name) -> {
  perform Logger::Log("hello \(name)")
}

handle { greet("world") } with Logger {
  Log(msg) => {
    stdout_write(msg)
    resume(())           // continue where perform left off
  }
}
```

### Effect polymorphism

```vibe
let apply: [T](f~: (T) -> T with { e }, x~: T) -> T with { e } = (f~, x~) -> {
  f(x)
}
```

## Module System

```vibe
// export
export let f: (Int) -> Int = (x) -> { x + 1 }
export enum Color { Red; Green; Blue }
export { name1, name2 }
export use ./lib.vibe { helper1, helper2 }  // re-export

// import
import ./lib.vibe { func1, func2 }
import ./lib.vibe { func1 as renamed }
import ./lib.vibe { type MyType, trait Show }

// module block
module Math {
  export let abs: (Int) -> Int = (x) -> { if x < 0 { 0 - x } else { x } }
}
Math::abs(-5)
```

Package refs: `@json`, `@lib/path` (hyphen/slash are part of name after `@`).
Qualified access: `Type::method`, `Module::name`.

## Tests

```vibe
test "arithmetic" {
  assert_eq(1 + 1, 2)
  assert(eq("a", "a"))
}
```

```bash
vibe test file.vibe
vibe test dir/            # run all tests in directory
```

## Key Builtins

**String**: `String::length`, `concat`, `substring`, `contains`, `index_of`, `split`, `trim`, `replace`, `starts_with`, `ends_with`, `join`

**Array**: `Array::length`, `get`, `slice`, `map`, `filter`, `fold`, `find`, `any`, `all`, `reverse`, `concat`

**Map**: `Map::get`, `has_key`, `keys`, `values`, `set`

**I/O** (require effects):
```vibe
stdout_write(s)    // with { Stdout }
stdin_read_line()  // with { Stdin }
sh("ls -la")       // with { Stdout } - shell command
sh_lines("ls")     // -> Array[String]
```

**Conversion**: `Int::to_string`, `Int::to_double`, `Double::to_int`, `String::from_char_code`

## Idioms

```vibe
// Result composition (railway-style)
let result =
  read_config()
  |> Result::and_then(parse)
  |> Result::and_then(process)

// Boundary at the edge
let value = handle { risky(0) } with Error { Throw(_) => default_value }

// Builder pattern
let arr = {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
}

// for-in as map
let doubled = for x in xs { x * 2 }

// pipe chain
input
  |> String::trim
  |> String::split(",")
  |> Array::map(_, parse_int)
```

## File Conventions

| File | Purpose |
|------|---------|
| `*.vibe` | Source |
| `index.vibe` | Package entry (exports `version`) |
| `index.lock` | Dependency lock |
| `*_test.vibe` | Tests |

---

*Full reference: [syntax-reference.md](language-tour/syntax-reference.md) / [language-tour/](language-tour/)*

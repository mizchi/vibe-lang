# Effects

vibe uses an explicit effect system. Functions declare required effects with `with { ... }`.

## Pure by default

Functions without `with { ... }` are pure -- they cannot perform I/O or throw errors.

```vibe
let add = (a: Int, b: Int) -> Int { a + b }  // pure
```

## Error handling

### throw / handle

`throw` raises an error. `handle` catches it locally.

```vibe
let safe_div = (a: Int, b: Int) -> Int with { Error } {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let result = handle { safe_div(8, 0) } { Error(_) => -1 }
// => -1
```

Calling a `with { Error }` function from a pure function requires `handle`:

```vibe
let safe = (x: Int) -> Int {
  handle { safe_div(x, 0) } { Error(_) => 0 }
}
```

### Railway-oriented Result pipeline (recommended)

Use `Result` composition in the pipeline core, and isolate error boundaries at edges.

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

let fetch_user_or_guest = (raw: String) -> String {
  match fetch_user(raw) {
    Ok(user) => user,
    Err(_) => "guest"
  }
}
```

Rule of thumb:

- Keep pipeline core in `Result` (`and_then`, `map_ok`, `map_err`).
- Place terminal boundaries (`handle`, `throw`, project-local `unwrap`) in adapter edges (CLI/HTTP/FFI/test helpers).
- Keep each boundary explicit and localized to one place per flow.

### suberror

Define typed error subtypes for structured error handling.

```vibe
suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

// Single constructor shorthand
suberror ParseError(String)

let risky = () -> Int with { Error } {
  throw(NotFound("missing"))
}

let result = handle { risky() } { Error(_) => -1 }
// => -1
```

`suberror` auto-registers `impl Error for <Type>`, so constructors can be used with `throw`.

## Algebraic effects (perform / resume)

User-defined effects use enum + `perform` / `resume`.

```vibe
enum Ask {
  Ask(Int)
}

let ask_once = () -> Int with { Ask } {
  perform(Ask(41))
}

let result = handle {
  add(1, ask_once())
} {
  Ask(v) => resume(add(v, 1))
}
// => 43
```

- `perform(Foo(...))` requires `{ Foo }` in the effect set
- `resume(v)` replaces the `perform` site result with `v` and re-evaluates the handled body

## Effect polymorphism

Effect row variables (`{ e }`) let higher-order functions propagate callee effects.

```vibe
let apply = [T, U](f: (T) -> U with { e }, x: T) -> U with { e } { f(x) }

apply((x: Int) -> Int { x + 1 }, 41)  // => 42
```

The wrapper must declare `with { e }` to propagate the callee's effects:

```vibe
// Error: wrapper does not declare { e }
let bad = [T](f: (T) -> T with { e }, x: T) -> T { f(x) }

// OK: Error is localized by handle
let safe = [T](f: (T) -> T with { Error }, x: T) -> T {
  handle { f(x) } { _ => x }
}
```

## Built-in effects

| Effect | Operations |
|--------|-----------|
| `Error` | `throw(...)` |
| `Stdout` | `sh(...)`, `sh_lines(...)`, `Stdout::write_char(...)`, `Stdout::write_stream(...)` |
| `Stdin` | `Stdin::read_char()`, `Stdin::read_stream(...)` |
| `Async` | `yield`, `sleep(...)` (requires `--unstable-async`) |

## Builders and `for-in`

Mutable builder APIs (`ArrayBuilder::new`, `MapBuilder::new`, `StringBuilder::new`) can be used
inside any function. `for-in` comprehensions desugar to builder operations internally:

```vibe
// for-in comprehension
let doubled = for x in [1, 2, 3] { x * 2 }

// Builder pattern (typically inside do for runtime shared-mut semantics)
let items = do {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 1)
  ArrayBuilder::push(b, 2)
  ArrayBuilder::freeze(b)
}
```

I/O builtins require the appropriate `with { Effect }` declaration:

```vibe
// OK: effect declared
let greet = (name: String) -> Unit with { Stdout } {
  Stdout::write_stream(name)
}

// Error: missing effect declaration
let bad = () -> Unit { sh("ls") }
```

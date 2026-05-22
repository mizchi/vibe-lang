# Effects

vibe uses an explicit effect system. Functions declare required effects with `with { ... }`.

## Pure by default

Functions without `with { ... }` are pure -- they cannot perform I/O or throw errors.

```vibe
let add: (Int, Int) -> Int = (a, b) -> { a + b }  // pure
```

## Error handling

### Railway-oriented Result pipeline (recommended)

Use `Result` composition in the pipeline core, and isolate error boundaries at edges.

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

let fetch_user_or_guest: (String) -> String = (raw) -> {
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

### throw / handle boundary

`throw` raises an `Error` effect. `handle` catches it locally at the boundary.

```vibe
let safe_div: (Int, Int) -> Int with { Error } = (a, b) -> {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let result = handle { safe_div(8, 0) } with Error { Throw(_) => -1 }
// => -1
```

Calling a `with { Error }` function from a pure function requires `handle`:

```vibe
let safe: (Int) -> Int = (x) -> {
  handle { safe_div(x, 0) } with Error { Throw(_) => 0 }
}
```

### suberror

Define typed error subtypes for structured error handling.

```vibe
suberror AppError {
  NotFound(String);
  InvalidInput(Int)
}

// Single constructor shorthand
suberror ParseError(String)

let risky: () -> Int with { Error } = () -> {
  throw(NotFound("missing"))
}

let result = handle { risky() } with Error { Throw(_) => -1 }
// => -1
```

`suberror` auto-registers `impl Error for <Type>`, so constructors can be used with `throw`.

## Algebraic effects (perform / resume)

User-defined effects use `effect` + `perform` / `resume`.

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

- `perform Effect::Op(...)` requires `{ Effect }` in the effect set
- `resume(v)` replaces the `perform` site result with `v` and re-evaluates the handled body

## Effect polymorphism

Effect row variables (`{ e }`) let higher-order functions propagate callee effects.

```vibe
let apply: [T, U]((T) -> U with { e }, T) -> U with { e } = (f, x) -> {
  f(x)
}

apply((x) -> { x + 1 }, 41)  // => 42
```

The wrapper must declare `with { e }` to propagate the callee's effects:

```vibe
// Error: wrapper does not declare { e }
let bad: [T]((T) -> T with { e }, T) -> T = (f, x) -> { f(x) }

// OK: Error is localized by handle
let safe: [T]((T) -> T with { Error }, T) -> T = (f, x) -> {
  handle { f(x) } with Error { Throw(_) => x }
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

`for-in` comprehensions desugar to builder operations internally:

```vibe
// for-in comprehension
let doubled = for x in [1, 2, 3] { x * 2 }
```

`do` is reserved and is not part of the current surface syntax.

I/O builtins require the appropriate `with { Effect }` declaration:

```vibe
// OK: effect declared
let greet: (String) -> Unit with { Stdout } = (name) -> {
  Stdout::write_stream(name)
}

// Error: missing effect declaration
let bad: () -> Unit = () -> { sh("ls") }
```

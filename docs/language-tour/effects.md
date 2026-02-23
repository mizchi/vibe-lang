# Effects

vibe uses an explicit effect system. Functions declare required effects with `with { ... }`.

## Pure by default

Functions without `with { ... }` are pure -- they cannot perform I/O, throw errors, or use mutable builders.

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
| `Stdout` | `sh(...)`, `sh_lines(...)`, `stdout_write_char(...)`, `stdout_write_stream(...)` |
| `Stdin` | `stdin_read_char()`, `stdin_read_stream(...)` |
| `Async` | `yield`, `sleep(...)` (requires `--unstable-async`) |

## do blocks

Mutable builder APIs (`array_builder`, `map_builder`, `string_builder`) and direct
I/O builtins are effectful. At top level, wrap them in `do { ... }` or use `for-in`:

```vibe
// do block
let items = do {
  let b = array_builder()
  array_builder_push(b, 1)
  array_builder_push(b, 2)
  array_builder_freeze(b)
}

// for-in (desugars to do internally — also pure)
let doubled = for x in [1, 2, 3] { x * 2 }

// function with do — callers inherit pure tier
let make = () -> Array[Int] {
  do { let b = array_builder(); array_builder_push(b, 1); array_builder_freeze(b) }
}
let xs = make()  // pure: make's value tier is Pure
```

Functions with declared effects (`with { Stdout }` etc.) are always impure — `do` cannot
override a missing effect declaration:

```vibe
// Error: do alone does not add missing effect declaration
let bad = () -> Unit { do { sh("ls") } }
```

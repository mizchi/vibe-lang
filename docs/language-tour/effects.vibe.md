# Effects

vibe uses an explicit effect system. Functions declare required effects with `with ...`.

## Pure by default

Functions without a `with` row cannot perform semantic effects such as I/O or
let an exception escape. An empty row does not guarantee termination or exclude
panic, Wasm trap, or resource exhaustion.

```vibe
let add: (Int, Int) -> Int = (a, b) -> { a + b }  // pure
```

## Error handling

### Failure-carrying pipeline (recommended)

Carry the failure in the effect row (`Exception[E]`) and isolate the boundary at
the edge. Success values flow straight through, so the stages just chain.

```vibe
// stub stages so the example is self-contained
fn parse_id(raw: String) -> Int with Exception[String] { 1 }
fn validate_id(id: Int) -> Int with Exception[String] { id }
fn load_user(id: Int) -> Int with Exception[String] { id }

fn fetch_user(raw: String) -> Int with Exception[String] {
  raw |> parse_id |> validate_id |> load_user
}

fn fetch_user_or_guest(raw: String) -> Int {
  handle { fetch_user(raw) } with Exception[String] {
    Throw(_) => 0 - 1     // guest
  }
}
```

Rule of thumb:

- Keep pipeline core in `Result` (`and_then`, `map_ok`, `map_err`).
- Place terminal boundaries (`handle`, `throw`, project-local `unwrap`) in adapter edges (CLI/HTTP/FFI/test helpers).
- Keep each boundary explicit and localized to one place per flow.

### throw / handle boundary

`throw` raises the `Exception` effect. `handle` catches it locally at the boundary.

```vibe
let safe_div: (Int, Int) -> Int with Exception = (a, b) -> {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let result = handle { safe_div(8, 0) } with Exception { Throw(_) => -1 }
// => -1
```

Calling a `with Exception` function requires the caller to propagate or handle
the effect:

```vibe
let safe_div: (Int, Int) -> Int with Exception = (a, b) -> {
  if eq(b, 0) { throw("division by zero") } else { a / b }
}

let may_raise: (Int) -> Int with Exception = (x) -> { safe_div(x, 0) }

let safe: (Int) -> Int = (x) -> {
  handle { safe_div(x, 0) } with Exception { Throw(_) => 0 }
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

let risky: () -> Int with Exception = () -> {
  throw(NotFound("missing"))
}

let result = handle { risky() } with Exception { Throw(_) => -1 }
// => -1
```

`suberror` auto-registers `impl Error for <Type>`, so constructors can be used with `throw`.

## Algebraic effects (perform / resume)

User-defined effects use `effect` + `perform` / `resume`.

```vibe
effect Ask {
  Question(Int) -> Int
}

let ask_once: () -> Int with Ask = () -> {
  perform Ask::Question(41)
}

// ADR-0076: the handle lives inside a function. A `handle` in a TOP-LEVEL
// `let` is not eligible for the evidence-passing migration, so
// `let result = handle { .. } with Ask { .. }` fails to compile.
fn answered() -> Int {
  handle {
    add(1, ask_once())
  } with Ask {
    Question(v) => resume(add(v, 1))
  }
}
// answered() => 43
```

- `perform Effect::Op(...)` requires `{ Effect }` in the effect set
- `resume(v)` replaces the `perform` site result with `v` and re-evaluates the handled body

## Effect polymorphism

Effect row variables (`{ e }`) let higher-order functions propagate callee effects.

```vibe
let apply: [T, U]((T) -> U with e, T) -> U with e = (f, x) -> {
  f(x)
}

let applied = apply((x) -> { x + 1 }, 41)  // => 42
```

The wrapper must declare `with e` to propagate the callee's effects:

> **Enforced (#885, fixed; previously a known gap tracked at #838):** this rule
> is now checked for the callback-parameter case — a wrapper whose body
> directly invokes an effect-row-polymorphic callback parameter without
> declaring a compatible row is rejected. The `bad` example below (missing
> `with e`) is a checker error today; see
> [vibe.md](../vibe.md#generics-with-effects-current) for the full scope note
> (call-site row-variable unification against a specific instantiating
> argument is a separate, still-open case).

<!-- doctest-skip: intentional type error example (ok/error contrast
     presentation) — `bad` is REJECTED by the checker (#885) and cannot share
     a single compiled unit with `safe`, so it stays a prose-only
     illustration; see the live `safe` block below for a verified compiling
     counterpart. -->
```vibe skip
// error (ENFORCED — #885): wrapper does not declare { e }
let bad: [T]((T) -> T with e, T) -> T = (f, x) -> { f(x) }
```

```vibe
// OK: the exception is localized by handle
let safe: [T]((T) -> T with Exception, T) -> T = (f, x) -> {
  handle { f(x) } with Exception { Throw(_) => x }
}
```

## Built-in effects

| Effect | Operations |
|--------|-----------|
| `Exception` | `throw(...)` |
| `Stdout` | `Stdout::write_char(...)`, `Stdout::write_stream(...)` |
| `Stdin` | `Stdin::read_char()`, `Stdin::read_stream(...)` |
| `Process` | `sh(...)`, `sh_lines(...)` |
| `Async` | `yield`, `sleep(...)` (requires `--unstable-async`) |

## Builders and `for-in`

`for-in` comprehensions desugar to builder operations internally:

```vibe
// for-in comprehension
let doubled = for x in [1, 2, 3] { x * 2 }
```

`do` is reserved and is not part of the current surface syntax.

I/O builtins require the appropriate `with Effect` declaration:

<!-- doctest-skip: 意図的な error 例 (missing effect declaration) を含む ok/error 対比の提示 -->
```vibe skip
// OK: effect declared
let greet: (String) -> Unit with Stdout = (name) -> {
  Stdout::write_stream(name)
}

// Error: missing effect declaration
let bad: () -> Unit = () -> { sh("ls") }
```

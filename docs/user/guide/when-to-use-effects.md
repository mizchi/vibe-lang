# When to Use Effects vs let mut

## The one question

**Should the caller of this function see, or decide, how this state changes?**

- **No → `let mut`**: the state is part of how the function works, and the
  caller has no reason to know about it.
- **Yes → an effect**: the caller decides how the operation is carried out —
  a test swaps in a mock, production uses the real thing.

## When `let mut` is the right tool

### 1. Loop counters

```vibe
// let mut: iteration control inside the function
let sum: (Array[Int]) -> Int = (arr) -> {
  let mut total = 0
  let mut i = 0
  while i < Array::length(arr) {
    total = total + Array::get(arr, i)
    i = i + 1
  }
  total
}
```

`i` and `total` are how `sum` works. The caller only sees the result.

### 2. StringBuilder / ArrayBuilder

```vibe
// let mut: intermediate state while building a value
let join: (Array[String], String) -> String = (parts, sep) -> {
  let sb = StringBuilder::new()
  let mut first = true
  for part in parts {
    if not(first) { StringBuilder::push(sb, sep) }
    StringBuilder::push(sb, part)
    first = false
  }
  StringBuilder::build(sb)
}
```

The buffer is invisible from outside; the result is an immutable `String`.

### 3. Local flags

```vibe
// let mut: a flag that never leaves the function
let has_uppercase: (String) -> Bool = (s) -> {
  let mut found = false
  let mut i = 0
  while i < String::length(s) {
    if String::byte_at(s, i) >= 65 && String::byte_at(s, i) <= 90 {
      found = true
    }
    i = i + 1
  }
  found
}
```

### 4. Accumulators with `for ... in`

```vibe
// let mut: the tally is internal logic
let count_even: (Array[Int]) -> Int = (arr) -> {
  let mut count = 0
  for x in arr {
    if x - (x / 2) * 2 == 0 { count = count + 1 }
  }
  count
}
```

## When an effect is the right tool

### 1. Calls to an external service

Files and HTTP already arrive as effects — the built-in `Fs` and `Http`
capabilities. Declare your own effect for a service the language does not
know about, such as a database:

```vibe
// effect: a test wants to replace the database
effect Db { Query(String) -> String }

let get_user: () -> String with Db = () -> {
  perform Db::Query("SELECT name FROM users WHERE id=1")
}

// in a test: a mock handler answers the query
let get_user_mocked: () -> String = () -> {
  handle { get_user() } with { Db::Query(_sql) => resume("Alice") }
}
```

A database call is an external dependency; a test should be able to swap it.

### 2. Configuration (dependency injection)

```vibe
// effect: the values differ per environment
effect Config { Get(String) -> String }

let connect: () -> String with Config = () -> {
  let host = perform Config::Get("DB_HOST")
  let port = perform Config::Get("DB_PORT")
  String::concat(host, String::concat(":", port))
}

// development settings
let connect_dev: () -> String = () -> {
  handle { connect() } with {
    Config::Get(key) => if key == "DB_HOST" {
      resume("localhost")
    } else {
      resume("5432")
    }
  }
}
```

Configuration changes with the environment, so it should not be hardcoded.

### 3. Logging and metrics

```vibe
// effect: the caller chooses where log lines go
effect Log { Info(String) -> Unit; Warn(String) -> Unit }

let process: (String) -> Int with Log = (data) -> {
  perform Log::Info("processing started")
  let result = String::length(data)
  if result == 0 {
    perform Log::Warn("empty data")
  }
  result
}

// in a test: discard the log
let process_quietly: (String) -> Int = (data) -> {
  handle { process(data) } with {
    Log::Info(_msg) => resume(());
    Log::Warn(_msg) => resume(())
  }
}
```

Logging is a side effect: a test does not need it, production does.

### 4. Authentication and authorization

```vibe
// effect: the check can be replaced
effect Auth { Verify(String) -> Bool }

let protected_action: () -> Int with Auth = () -> {
  let ok = perform Auth::Verify("token")
  if ok { 200 } else { 401 }
}

// in a test: every token is accepted
let protected_action_trusted: () -> Int = () -> {
  handle { protected_action() } with { Auth::Verify(_token) => resume(true) }
}
```

Authentication is a security boundary; a test should be able to make it
always succeed (or always fail).

### 5. Random numbers

```vibe
// effect: a test wants a deterministic answer
effect Random { NextInt(Int, Int) -> Int }

let roll_dice: () -> Int with Random = () -> {
  perform Random::NextInt(1, 6)
}

// in a test: always 4
let roll_dice_fixed: () -> Int = () -> {
  handle { roll_dice() } with { Random::NextInt(_lo, _hi) => resume(4) }
}
```

Randomness is nondeterministic; a test should not be.

### 6. Values produced for the caller to consume

```vibe
// effect: the producer emits, the caller decides what to do with each value
effect Emit { Emit(Int) -> Unit }

let produce: () -> Unit with Emit = () -> {
  perform Emit::Emit(10)
  perform Emit::Emit(20)
  perform Emit::Emit(30)
}

// this caller sums the values: 10 + 20 + 30 = 60
let total: () -> Int = () -> {
  let mut sum = 0
  handle { produce() } with {
    Emit::Emit(v) => {
      sum = sum + v
      resume(())
    }
  }
  sum
}
```

Another caller could count, print, or stop early without `produce` changing.
A handler arm ends with `resume(...)`: it cannot add to what `resume`
returns, so the running total is a `let mut` the arm updates.

## Decision flowchart

```
This variable / operation…
│
├─ Does it affect anything outside the function?
│  ├─ Yes → an effect
│  │  ├─ Files / HTTP? → the built-in Fs / Http capabilities
│  │  ├─ A database or other service? → effect Db
│  │  ├─ Configuration? → effect Config
│  │  ├─ Logging? → effect Log
│  │  ├─ Authentication? → effect Auth
│  │  └─ Randomness? → effect Random
│  │
│  └─ No → let mut
│     ├─ Loop counter? → let mut i = 0
│     ├─ Running total? → let mut total = 0
│     ├─ Building a value? → StringBuilder / ArrayBuilder
│     └─ Flag? → let mut found = false
│
└─ Will a test want to replace it?
   ├─ Yes → an effect (a mock handler replaces it)
   └─ No → let mut (it stays an implementation detail)
```

## Anti-patterns

### Don't turn a counter into an effect

```vibe
// BAD: an effect for state only this function sees
effect Counter { Inc() -> Unit; Get() -> Int }

let count_bad: () -> Int = () -> {
  let mut n = 0
  handle {
    perform Counter::Inc()
    perform Counter::Inc()
    perform Counter::Get()
  } with {
    Counter::Inc() => {
      n = n + 1
      resume(())
    };
    Counter::Get() => resume(n)
  }
}

// GOOD: a let mut is enough
let count_good: () -> Int = () -> {
  let mut n = 0
  n = n + 1
  n = n + 1
  n
}
```

### Don't turn a pure function into an effect

```vibe
// BAD: concatenating strings is not a side effect
effect StringOps { Concat(String, String) -> String }

// GOOD: call the function
let greet: (String) -> String = (name) -> { String::concat("hello, ", name) }
```

### Don't try to remove every `let mut`

```vibe
// BAD: an effect whose only handler sits in the same function
effect Acc { Add(Int) -> Unit }

let sum_bad: (Array[Int]) -> Int = (arr) -> {
  let mut total = 0
  handle {
    for x in arr { perform Acc::Add(x) }
  } with {
    Acc::Add(v) => {
      total = total + v
      resume(())
    }
  }
  total
}

// GOOD: write the let mut directly (simpler and faster)
let sum_good: (Array[Int]) -> Int = (arr) -> {
  let mut total = 0
  for x in arr { total = total + x }
  total
}
```

Section 6 above has the same shape, but there the producer is a separate
function whose callers each choose a handler. Here nothing else ever
handles `Acc`, so the effect only adds indirection.

## Summary

| | `let mut` | effect |
|---|---|---|
| **Scope** | inside one function | module / system boundary |
| **Testing** | nothing to replace | a mock handler replaces it |
| **Visibility** | hidden from the caller | appears in the type signature |
| **Cost** | a wasm local; a heap cell if a closure captures it (`vibe escapes` lists those) | a `perform` costs about 1.7× a function call and allocates nothing; carrying the effect in a row costs nothing measurable ([measurements](../../internal/compiler/tracing-design.md)) |
| **Typical uses** | counters, builders, flags | databases, HTTP, configuration, logging, authentication |

# 13 — Effects (the heart of vibe)

Previous: [04 Option](08_option.vibe.md)

日本語版: [13_effects.vibe.md](../ja/13_effects.vibe.md)

vibe is **pure by default**. A side effect is declared in the type's `with ...`
row (the effect row) and propagates to the caller until a `handle` draws the
boundary.

## The Exception boundary — perform / handle

`Exception` without a type argument is an erased, **abortive** (non-resumable)
effect, and it is compatible with every kind of typed `Exception[E]`.
`perform Exception::Throw` does not resume the continuation, and `resume` is not
available in its handler arm — that arm's value becomes the result of the
`handle`. An erased handler treats its payload as String/opaque and does not
preserve type arguments across the handler. For when to reach for a typed
exception instead, see [ADR-0085](../../docs/exception-effect.md).

```vibe run
fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    perform Exception::Throw("division by zero")
  }
  100 / x
}

fn main with Console {
  let safe = handle {
    risky(0)
  } with Exception {
    Throw(message) => {
      println("exception: \{message}")
      0 - 1
    }
  }
  let fine = handle {
    risky(4)
  } with Exception {
    Throw(_) => 0 - 1
  }
  println("safe = \{safe}")
  println("fine = \{fine}")
}
```

```output
exception: division by zero
safe = -1
fine = 25
```

## Migrating from the old `Error` spelling

`Error` is a parse error both in an effect row (`with Error`) and as a handler
name (`handle { ... } with Error { ... }`). `vibe fmt` rewrites old sources to
`Exception`. `throw("message")` still works.

Only the operation qualifier `perform Error::Throw(...)` is still accepted, as
internal compatibility for reading older artifacts; new source uses
`perform Exception::Throw(...)`.

Rejected old spellings, `skip`ped because this is a migration note rather than a
runnable example:

```vibe skip
// Rejected source (kept in comments so `vibe fmt` does not rewrite the example):
// fn old_row() -> Int with Error { throw("old") }
// fn old_handler() -> Int {
//   handle { 1 } with Error { Throw(_) => 0 }
// }
```

## User-defined effects — perform / resume

An effect is a *declaration of operations*. The implementation — the handler —
is supplied by the caller.

```vibe run
effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Console {
  // the handler returns a value to the perform site via resume(v) (one-shot tail-resumptive)
  let v = handle {
    answer_of("life")
  } with Ask {
    Value(_q) => resume(41)
  }
  println("v = \{v}")
}
```

```output
v = 42
```

A user-defined effect is the advanced tool, for when the caller genuinely has to
swap the implementation. It comes with the constraint of being resumptive and
one-shot/tail-resumptive. For ordinary failure use `Exception`, and for local
state consider `let mut` first. The criteria are in
[Effects vs let mut](../../docs/guide/when-to-use-effects.md).

## What a `handle` can see

`handle { answer_of(...) }` above compiles because `answer_of` is a named
top-level `fn`. Every `perform` a `handle` covers has to be visible to it, so
the compiler has to be able to tell, for each call in the handled body, what
that call performs.

Most calls are visible: a top-level `fn`, a builtin like `println`, a closure
whose binding or parameter carries the effect row, and a closure written inside
the handled body. What is *not* visible is a rowless closure the handled body
only sees as a name from an outer scope — the compiler has no definition to
look at and no row to read. That shape type-checks and is still rejected;
rewrite the call, not the types.

```vibe skip
// skip: ineligible handle — a rowless closure bound outside the handled body
effect Ask {
  Once() -> Int
}

fn ask_once() -> Int with Ask {
  perform Ask::Once()
}

fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { bump(ask_once()) } with Ask {
    Once() => resume(41)
  }
}
// error (measured with `vibe check`): handle of effect 'Ask' cannot be compiled
// here: this handle cannot see what one call in its body performs (here: the
// call to 'bump'). Make that call visible -- declare 'bump' as a top-level
// `fn`, give the binding or parameter it arrives through an effect row (`with
// Ask`), or move its `let` inside the handled body. Moving the `handle` into
// the function that performs works too.
```

Any one of the four repairs the message lists fixes it. The smallest here is to
hoist `bump` to a top-level `fn`; writing `let bump: (Int) -> Int with Ask =
...`, or moving the `let` inside the `handle`, works just as well.

## Effect polymorphism

An effect row can be a variable, which is how you write a higher-order function
that carries whatever effects the function it was handed has.

```vibe run
fn apply_twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main with Console {
  println("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}")
}
```

```output
apply_twice = 40
```

Host I/O (`Fs`, `Env`, `Http`, **`Console`**) are **capabilities**, not
algebraic effects. On a *split* signature they belong in `allows`, not
`with`. The current tty capability is `Console` (`Console::write_stream`,
`read_stream`, `write_err_stream`, and the `*_char` pair). `Stdout` /
`Stdin` / `Stderr` are still-accepted **legacy labels** that share those
host imports. Declaring `Console` authorizes them; declaring one of them
does **not** authorize `Console::*`, because `Console` is the wider
capability. See [Capabilities](14_capabilities.vibe.md).

Next: [Capabilities](14_capabilities.vibe.md). The package/test tour is
[Modules](09_modules_packages.vibe.md) then [Tests](10_tests.vibe.md).

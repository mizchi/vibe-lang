# 05 — Effects (the heart of vibe)

Previous: [04 Option](04_option.vibe.md)

日本語版: [05_effects.vibe.md](../ja/05_effects.vibe.md)

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
exception instead, see [ADR-0085](../exception-effect.md).

```vibe run
import @vibe/prelude {
  stdout_write
}

fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    perform Exception::Throw("division by zero")
  }
  100 / x
}

fn main with Stdout {
  let safe = handle {
    risky(0)
  } with Exception {
    Throw(message) => {
      stdout_write("exception: \{message}\n")
      0 - 1
    }
  }
  let fine = handle {
    risky(4)
  } with Exception {
    Throw(_) => 0 - 1
  }
  stdout_write("safe = \{safe}\n")
  stdout_write("fine = \{fine}\n")
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
import @vibe/prelude {
  stdout_write
}

effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Stdout {
  // the handler returns a value to the perform site via resume(v) (one-shot tail-resumptive)
  let v = handle {
    answer_of("life")
  } with Ask {
    Value(_q) => resume(41)
  }
  stdout_write("v = \{v}\n")
}
```

```output
v = 42
```

A user-defined effect is the advanced tool, for when the caller genuinely has to
swap the implementation. It comes with the constraint of being resumptive and
one-shot/tail-resumptive. For ordinary failure use `Exception`, and for local
state consider `let mut` first. The criteria are in
[Effects vs let mut](../guide/when-to-use-effects.md).

## What a `handle` can see

`handle { answer_of(...) }` above compiles because `answer_of` is a named
top-level `fn`. Every `perform` a `handle` covers has to be statically visible
to it: a direct `perform`, a call to a named top-level `fn`, or a closure
literal that carries an effect-row annotation.

A call through a local binding hides the perform. That shape type-checks and is
still rejected — rewrite the call, not the types.

```vibe skip
// skip: ineligible handle — a local closure hides the perform from the handler
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
// here. Every perform this handle covers has to be statically visible to it, so
// the handled body may only: perform directly, call a named top-level `fn`, or
// call a closure literal that carries an effect row annotation. A call through
// a local binding or a closure parameter hides the perform and is what this
// rejects (here: the call to 'bump') -- move the `handle` into the function
// that performs, or replace the indirect call with a direct one.
```

The last sentence is the rewrite: move the `handle` into the function that
performs, or replace `bump(...)` with a direct call (or a top-level `fn`).

## Effect polymorphism

An effect row can be a variable, which is how you write a higher-order function
that carries whatever effects the function it was handed has.

```vibe run
import @vibe/prelude {
  stdout_write
}

fn apply_twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main with Stdout {
  stdout_write("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}\n")
}
```

```output
apply_twice = 40
```

Host I/O (`Fs`, `Env`, `Http`, **`Console`**) are **capabilities**, not
algebraic effects. On a *split* signature they belong in `allows`, not
`with`. The current tty capability is `Console` (`Console::write_stream`,
`read_stream`, `write_err_stream`, and the `*_char` pair). `Stdout` /
`Stdin` / `Stderr` in the examples above are still-accepted **legacy
labels** that share those host imports; they do not authorize `Console::*`
and the other way around. See [Capabilities](10_capabilities.vibe.md).

Next: [Capabilities](10_capabilities.vibe.md). The package/test tour is
[Modules](07_modules_packages.vibe.md) then [Tests](06_tests.vibe.md).

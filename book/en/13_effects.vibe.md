# 13 — Effects (the heart of vibe)

Previous: [Iteration](12_iteration.vibe.md)

日本語版: [13_effects.vibe.md](../ja/13_effects.vibe.md)

A function in vibe is pure unless its type says otherwise. Anything it
can do besides compute — fail, print, read a file — is named in a `with`
clause on the signature, and that clause propagates to every caller
until someone handles it.

That is the whole mechanism. This chapter is what it looks like.

## Declaring that a function can fail

`Exception` is the effect for failure. A function that may throw says so,
and callers inherit the obligation:

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

`handle { body } with Exception { ... }` is the boundary. Inside it,
`risky` may throw; outside it, `main` has no `Exception` in its row,
because the obligation was discharged.

`Exception` is **abortive**: a throw does not come back. The handler arm's
value becomes the value of the whole `handle` — that is why `safe` is
`-1` and `fine` is `25`. There is no `resume` in an `Exception` arm.

Written without a type argument, `Exception` is erased: it accepts any
`Exception[E]`, and its payload arrives as a string. When you want the
error type preserved, write `Exception[E]` — see
[the exception effect](../../docs/exception-effect.md).

## Declaring your own effect

An effect declaration is a list of operations with no implementation.
The caller supplies the implementation, in the handler. This is the part
`Exception` is a special case of:

```vibe run
effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Console {
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

`answer_of` does not know where the number comes from. It performs
`Ask::Value` and continues with whatever the handler resumes — here `41`,
so `answer_of` returns `42`. Unlike `Exception`, `Ask` **is** resumable:
`resume(v)` sends `v` back to the `perform` site and the function carries
on.

Resumption is one-shot and tail-resumptive: a handler arm resumes at most
once, as its last act.

Reach for your own effect when the caller genuinely has to swap the
implementation — a clock in tests, a different source for a value. For
ordinary failure use `Exception`; for local state try `let mut` first.
[Effects vs let mut](../../docs/guide/when-to-use-effects.md) has the
criteria.

## Rows can be variables

A higher-order function should not have to know which effects the
function it was handed performs. Write the row as a variable and it
carries whatever arrives:

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

`apply_twice` is pure when `f` is pure, and carries `Exception` when `f`
throws. One definition, both cases, checked.

## The one rule about `handle`

A `handle` has to be able to see every `perform` it covers. For each call
in the handled body, the compiler needs to know what that call performs.

Most calls it can see: a top-level `fn`, a builtin, a closure whose
binding or parameter carries an effect row, and a closure written inside
the handled body. The shape it cannot see is a **rowless closure bound
outside** the handled body — there is no definition to look at and no row
to read. It type-checks and is still rejected:

```vibe skip
// skip: this is the rejected shape, shown for the diagnostic it produces
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
```

```
handle of effect 'Ask' cannot be compiled here: this handle cannot see what
one call in its body performs (here: the call to 'bump'). Make that call
visible -- declare 'bump' as a top-level `fn`, give the binding or parameter
it arrives through an effect row (`with Ask`), or move its `let` inside the
handled body. Moving the `handle` into the function that performs works too.
(ADR-0076 evidence-passing migration.)
```

The message lists four repairs and any one of them works; here the
smallest is to make `bump` a top-level `fn`. The ADR reference at the end
is a maintainer's note — the four repairs are the part addressed to you.

## Effects you do not handle: capabilities

`Fs`, `Env`, `Http` and `Console` ride the same row, but you do not write
handlers for them — the host provides them, and what you declare is
permission to use them. That is the next chapter.

Next: [Capabilities](14_capabilities.vibe.md).

# 17 — Concurrency

Previous: [Equality](16_equality.vibe.md)

日本語版: [17_concurrency.vibe.md](../ja/17_concurrency.vibe.md)

You do not spawn threads in vibe. You open a `TaskGroup`, spawn work
into it, and join the results — and the group does not outlive the call
that opened it. Everything is scoped, which is what makes the rest
checkable.

The package is `@vibe/concurrent`.

**This chapter is the one unstable surface in the book.** Everything here is
ADR-0068, which is still `proposed`: `Nursery`, `Task`, `Sender`/`Receiver`,
`TaskGroup::run` / `spawn` / `spawn_suspend`, and the compiler's `Send` rule.
It is outside the SemVer promise and can change within a Minor release — see
[the stable surface](../../docs/spec/stable-surface.md) §6. What it decides is
settled enough to build on; what is not settled is the `Send`/region checking
and which backend runs it (today's scheduler is a cooperative
run-to-completion prototype).

The `Async` effect itself is NOT in that bucket. ADR-0012 is accepted, and
`with Async` on a row is as stable as any other effect — it appears in shipped
builtin signatures like `StdinStream::next`. The unstable part is the
concurrency model built on top of it, not the vocabulary.

## Spawning and joining

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main with Console + Exception {
  let answer = TaskGroup::run((n) -> {
    let h = TaskGroup::spawn(n, () -> {
      21 * 2
    })
    TaskHandle::join(h)
  })
  println("answer = \{answer}")
}
```

```output
answer = 42
```

`TaskGroup::run` hands its body a group `n`. `spawn` starts work in it
and gives back a handle; `join` waits for the value. When `run` returns,
the group is finished — there is nothing left running that you would
have to remember to clean up.

The `+ Exception` on `main` is not decoration: a spawned task can fail,
and `join` rethrows that failure as a `TaskError`, so `join`'s own row
carries `Exception[TaskError]`. Leave it off `main` and the compiler
tells you the exact edit — `` hint: add 'with Console +
Exception[TaskError]' to 'main' `` (the plain `Exception` written above
covers it).

## What may cross a spawn

Spawned work runs somewhere you do not control, so what it captures has
to be safe to move. That is the `Send` judgement, and the compiler makes
it structurally — you never write `impl Send`:

| may cross | may not |
|---|---|
| scalars, tuples | closures |
| `Option` of `Send` parts | `Array`, `Bytes` |
| structs and enums built from `Send` parts, with no `mut` fields | anything with a `mut` field |

The body you hand to `spawn` is itself a closure, and that one is fine —
the table is about what that body *captures* and what you send between
tasks, not about the body.

`FrozenArray[T]` exists for exactly this: an array you can send. A
persistent `Map` is not automatically `Send`.

## The group cannot escape

`TaskGroup::run` opens a region, and the things that belong to it — the
group, handles, senders, receivers — may not be in the value the body
returns. Returning a handle would hand you something whose group has
already finished, so the compiler rejects it instead.

One hole worth knowing: the spawn check fires when `TaskGroup::spawn` is
written literally. Reaching it through a rename (`let spawn =
TaskGroup::spawn`) skips the check.

## Suspending versus blocking

Two flavours of every waiting operation, and the difference is whether
siblings get to run:

| blocks the instance | suspends the task |
|---|---|
| `sleep` | `sleep_wait` |
| `send` / `recv` | `send_wait` / `recv_wait` |

Reach for the `_wait` forms inside a `TaskGroup`; the blocking ones stop
everything, not just the caller.

Suspension is carried by an `Async` effect on this package, declared as
`Suspend(Int) -> Int`. It is a library effect like any other — not a
keyword, and it shows up in rows the same way.

## Shared-nothing

Messages are values, and the intended semantics are a deep copy between
tasks. Today all tasks still share one heap, so send immutable data and
the two agree. When real threads land, the model stays shared-nothing —
`TaskGroup` plus the `Send` and region checks already describe that
shape, which is why they are enforced now.

Next: [The CLI as an IDE](18_cli.vibe.md).

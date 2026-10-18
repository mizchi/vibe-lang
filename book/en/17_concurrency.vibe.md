# 17 — Concurrency

Previous: [Equality](16_equality.vibe.md)

日本語版: [17_concurrency.vibe.md](../ja/17_concurrency.vibe.md)

You do not spawn threads in vibe. You open a `TaskGroup`, spawn work
into it, and join the results — and the group does not outlive the call
that opened it. Everything is scoped, which is what makes the rest
checkable.

The package is `@vibe/concurrent`, and it is stable: task groups, task
handles, bounded channels, `Parallel::map`, and the compiler's `Send` and
region checks need no opt-in. The scheduler behind them is cooperative and
deterministic — a task runs until it waits — and the model is fixed
independently of that: moving the same programs onto a parallel backend
later does not change what they mean.

One part is still experimental: the suspendable-task lane
(`TaskGroup::spawn_suspend`, `pump_all`, `sleep_wait`, `send_wait` /
`recv_wait`, `result_wait`) lives in `@vibe/concurrent/experimental`, and
importing that package is refused unless the build is run with
`VIBE_UNSTABLE=1`. It is outside the SemVer promise and can change within a
Minor release — see [the stable surface](../../docs/user/reference/stable-surface.md) §6.

Waiting without blocking is the `Async` effect, and it is stable. There is
one `Async` label, built into the language, with one operation
(`Async::Suspend`). Builtins that may wait carry it — `sleep`, `await`,
`StdinStream::next` — and a function that calls one carries it too, like any
other effect; `main` writes `allows Async`. The experimental package's
`effect Async { Suspend(Int) -> Int }` is not a second effect: it spells out
that same builtin label so the package can handle it.

## Spawning and joining

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main allows Console + Exception {
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

`TaskGroup::run` hands its body a group `n`. `spawn` queues work in it and
gives back a handle; `join` waits for the value. When `run` returns, the
group is finished — there is nothing left running that you would have to
remember to clean up.

`taskgroup { n => { .. } }` is a keyword spelling of the same call: it
parses to exactly `TaskGroup::run((n) -> { .. })`.

The `+ Exception` on `main` is not decoration: a spawned task can fail,
and `join` rethrows that failure as a `TaskError`, so `join`'s own row
carries `Exception[TaskError]`. Leave it off `main` and the compiler
tells you the exact edit — `` hint: add 'allows Console +
Exception[TaskError]' to 'main' `` (the plain `Exception` written above
covers it).

## When a task runs

`spawn` does not run anything. It puts the task at the back of the group's
ready queue and returns at once. Queued tasks run, first in first out, when
the code that spawned them waits: `join`, a channel `send` or `recv`, or the
end of the `run` body, which runs whatever is still queued before the group
closes. A task that starts runs to its end.

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main allows Console + Exception {
  let total = TaskGroup::run((g) -> {
    let a = TaskGroup::spawn(g, () -> {
      println("task a")
      1
    })
    let b = TaskGroup::spawn(g, () -> {
      println("task b")
      2
    })
    println("after spawn")
    let vb = TaskHandle::join(b)
    println("joined b = \{vb}")
    let va = TaskHandle::join(a)
    println("joined a = \{va}")
    va + vb
  })
  println("total = \{total}")
}
```

```output
after spawn
task a
task b
joined b = 2
joined a = 1
total = 3
```

Joining `b` first still runs `a` first: `join` drains the queue in order until
the task it waits for has finished. The order is the same on every run.

## Failure and cancellation

A task that throws fails, and so does the group: its queued siblings are
cancelled, and `join` on the failed task — or the close of the group —
throws `TaskError::Failed(message)`, with the task's error rendered into the
message. To observe it, handle `Exception[TaskError]` around `run`:

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle, TaskError
}

fn main allows Console + Exception {
  let r = handle {
    TaskGroup::run((g) -> {
      let a = TaskGroup::spawn(g, () -> {
        throw("boom")
        1
      })
      TaskHandle::join(a)
    })
  } with Exception[TaskError] {
    Throw(e) => {
      println("caught \{e}")
      0
    }
  }
  println("r = \{r}")
}
```

```output
caught Failed(boom)
r = 0
```

`TaskHandle::cancel(h)` asks a task to stop. A task that has not started yet
never starts, and joining it throws `TaskError::Cancelled`; on a task that has
already finished, `cancel` does nothing. A task that is already running is not
interrupted: it runs to its end, and only a task that has not started, or a
suspendable task parked at a wait, is stopped. Cancelling one task does not
fail the group: its siblings keep running.

## Channels

`Channel::bounded(g, capacity)` makes a channel in group `g` and returns its
two ends, a `Sender` and a `Receiver`. Capacity `0` is a rendezvous: every
send waits for a receiver. A negative capacity throws
`ChannelConfigError::NegativeCapacity`.

```vibe run
import @vibe/concurrent {
  TaskGroup, TaskHandle, Channel, Sender, Receiver
}

fn main allows Console + Exception {
  let sum = TaskGroup::run((g) -> {
    let (tx, rx) = Channel::bounded(g, 1)
    let producer = TaskGroup::spawn(g, () -> {
      for i in [1, 2, 3] {
        Sender::send(tx, i)
      }
      Sender::release(tx)
    })
    let mut total = 0
    let mut done = false
    while !done {
      match Receiver::recv(rx) {
        Some(v) => {
          total = total + v
        }
        None => {
          done = true
        }
      }
    }
    TaskHandle::join(producer)
    total
  })
  println("sum = \{sum}")
}
```

```output
sum = 6
```

- `Sender::send` returns once the message is buffered, or handed to a
  receiver that is already waiting for it further down the stack -- so the
  sender can go on running before that receiver has resumed. When there is no
  room and no receiver waiting, it runs the group's queued tasks until a
  receiver takes it.
- `Receiver::recv` returns `Some(v)`, or `None` once the channel is closed
  **and** drained: messages already buffered are still delivered.
- A channel closes when its last sender is released. `Sender::clone` adds a
  sender; each one must be released with `Sender::release`. Sending on a
  closed channel throws `SendError::Closed`.
- Waiting with nothing left to run is a deadlock, and it traps with a
  message rather than hanging. A run-to-completion task that blocks in
  `send` waits *under* the task it drove, so two tasks that each need the
  other's next step deadlock; receive in the `run` body, as above, or use a
  suspendable task.

## `Parallel::map`

`Parallel::map(g, xs, f)` runs `f` on every element as a task of `g` and
returns the results in the order of `xs`:

```vibe run
import @vibe/concurrent {
  TaskGroup, Parallel
}

fn main allows Console + Exception {
  let ys: Array[Int] = TaskGroup::run((g) -> {
    Parallel::map(g, [3, 1, 2], (x) -> x * 10)
  })
  println("\{ys}")
}
```

```output
[30, 10, 20]
```

The results are index-ordered whatever order the tasks finish in, so a
program cannot observe completion order through them. The elements and the
results cross a task boundary, so both must be `Send`.

## What may cross a spawn

Spawned work runs somewhere you do not control, so what it captures and what
it returns have to be safe to move. That is the `Send` judgement, and the
compiler makes it from a type's structure — you never write `impl Send`, and
an `impl Send` is refused:

| `Send` | not `Send` |
|---|---|
| `Int`, `Double`, `Bool`, `Char`, `String`, `Unit` | `Array`, `Bytes` |
| tuples and `Option` of `Send` parts | anything with a `mut` field |
| structs and enums built from `Send` parts | `Map`, host resources, opaque handles |
| `FrozenArray[T]` of a `Send` `T` | a function value |

`Send` is checked wherever a value moves between tasks: a task's result, a
channel's element type, and `Parallel::map`'s inputs and outputs. A task that
returns a function, or an `Option[Array[Int]]`, is refused at the `spawn`.
`FrozenArray[T]` exists for exactly this: an array you can send. A `Map` is
never `Send`; send the entries instead.

What a task *captures* is judged the same way, capture by capture. The body
you hand to `spawn` is itself a closure, and that one is fine. A closure it
calls is fine too when that closure's own captures are — capturing
`let inc = (x: Int) -> x + 1` is accepted, and the same closure capturing an
`Array` is refused. A task may also capture its own group's handles,
senders and receivers. A `let mut` is never capturable: it would share one
mutable cell between tasks.

## The group cannot escape

`TaskGroup::run` opens a region, and the things that belong to it — the
group, handles, senders, receivers — may not be in the value the body
returns. Returning a handle would hand you something whose group has
already finished, so the compiler rejects it instead.

Both checks follow the function, not how you spell it: a local alias
(`let spawn = TaskGroup::spawn`) or a renamed import is checked like the
direct call, and so is `TaskGroup::run`. Handing either on as a value —
an argument, a field, a return value — is refused, because the check
could not see the closure it would later be applied to.

The spawn check has to see what the closure captured. A closure written
at the call, a closure bound by a local `let work = () -> ...`, and a
top-level function passed by name all qualify, and a local closure the
body calls counts as a capture. A closure the check cannot see into —
say, a parameter of your own helper — is refused. The exception is a
helper shaped like `spawn` (a `TaskGroup` first, a closure last, as
`Parallel::map` is): its callers' closures are checked, so inside it the
parameter can be spawned.

## Suspending versus blocking

There are three ways to wait, and they differ in what else gets to run:

| waits by | siblings | operations |
|---|---|---|
| blocking the instance | nothing runs | `sleep_blocking` |
| driving on the caller's stack | queued siblings run to completion | `join`, `send` / `recv` |
| suspending the task | siblings interleave with it | `sleep`, `await`, and in a suspendable task `sleep_wait`, `send_wait` / `recv_wait`, `result_wait` |

`join`, `send` and `recv` are not blocking: while the caller waits, they run
the group's queued tasks on its stack until the value, the room or the
message it needs is there. What they cannot do is pause the caller mid-body
and come back to it later, so a task that has to wait halfway through for a
sibling which in turn waits on it cannot be written that way.
`sleep_blocking(ms)` stops everything.

Suspending carries `Async`, and it needs somewhere to suspend to. An entry
that allows `Async` is one: `sleep` and `await` called from `main`, or from a
function with `Async` in its row, suspend there. A task started with
`TaskGroup::spawn` is not: it runs to completion, so a task that uses
`Async` — `sleep`, a `_wait` operation, or a function whose row carries
`Async` — is refused, with the edit to start it with
`TaskGroup::spawn_suspend`. The same holds for the `run` body itself: move
the wait out of it, or into a suspendable task.

## Suspendable tasks

`TaskGroup::spawn_suspend`, from `@vibe/concurrent/experimental` (so the
build needs `VIBE_UNSTABLE=1`), starts a task that can suspend. Inside it,
`sleep` and `sleep_wait` park the task so its siblings run,
`TaskHandle::result_wait` is the suspending `join`, and `send_wait` /
`recv_wait` are the suspending channel operations. `TaskGroup::pump_all(g)`
runs parked tasks until none is left; a `join` on a parked task does the same
for that task.

```vibe run
import @vibe/concurrent/experimental {
  TaskGroup, TaskHandle, sleep_wait
}

fn main allows Console + Exception + Async {
  let total = TaskGroup::run((g) -> {
    let a = TaskGroup::spawn_suspend(g, () -> {
      println("a1")
      sleep_wait(10)
      println("a2")
      1
    })
    let b = TaskGroup::spawn_suspend(g, () -> {
      println("b1")
      let va = TaskHandle::result_wait(a)
      println("b2 saw a = \{va}")
      va + 1
    })
    TaskGroup::pump_all(g)
    TaskHandle::join(a) + TaskHandle::join(b)
  })
  println("total = \{total}")
}
```

```output
a1
b1
a2
b2 saw a = 1
total = 3
```

`a` suspends at its sleep and `b` runs until it waits for `a`; then `a`
finishes and wakes `b`. A suspendable task's closure needs no row of its own:
`spawn_suspend` expects an `Async` closure, and the task may use the entry's
capabilities (`Console` here). Sleeps overlap rather than add up, and no wall
clock is read.

## Futures and async iteration

The waits above belong to tasks. Two builtin types carry waiting as a value.

`Future[T]` is a handle to a value that may not exist yet.
`Future::pending()` makes an unresolved one, `Future::resolve(f, v)` fills
it, `Future::ready(v)` is already filled, and `await(f)` suspends until the
value is there.

An async iterator is a value whose `next` returns
`Future[Option[(T, Self)]]`: the next element and the rest, or `None` at the
end. `for x in it` over such a value awaits each step, so it carries `Async`.
Whether a `for` is the eager array loop or the await loop is decided by the
iterand's type alone; there is no `for await`.

`AsyncIter` is the library form of the same pull model, entered explicitly
with `Array::iter`. Its `map`, `filter`, `take` and `take_while` are lazy;
`collect`, `fold`, `count` and friends pull and carry `Async`.

```vibe run
import @vibe/builtin {
  Array::iter,
  AsyncIter::collect,
  AsyncIter::map
}

struct Countdown {
  n: Int
}

fn Countdown::next(c: Countdown) -> Future[Option[(Int, Countdown)]] {
  if c.n <= 0 {
    Future::ready(None)
  } else {
    Future::ready(Some((c.n, Countdown::{ n: c.n - 1 })))
  }
}

fn sum_down(n: Int) -> Int with Async {
  let mut acc = 0
  for x in Countdown::{ n: n } {
    acc = acc + x
  }
  acc
}

fn tens() -> Array[Int] with Async {
  [1, 2, 3]
    |> Array::iter
    |> AsyncIter::map((x) -> { x * 10 })
    |> AsyncIter::collect
}

fn main allows Console + Async {
  let f = Future::pending()
  Future::resolve(f, 41)
  let v = await(f)
  println("v = \{v + 1}")
  println("sum = \{sum_down(4)}")
  let ys = tens()
  println("tens = \{ys}")
}
```

```output
v = 42
sum = 10
tens = [10, 20, 30]
```

A stream the host owns, such as an HTTP response body, is a `HostStream`,
whose `next` carries `Async` too, so a `for` over one awaits each byte the
same way. How `Future`, `HostStream` and `ByteStream` map onto WASI 0.3
futures and streams is in
[wasi-p3-async.md](../../docs/internal/design/wasi-p3-async.md).

## Shared-nothing

Messages are values, and the intended semantics are a deep copy between
tasks. Today all tasks still share one heap, so send immutable data and
the two agree. When real threads land, the model stays shared-nothing —
`TaskGroup` plus the `Send` and region checks already describe that
shape, which is why they are enforced now.

Next: [The CLI as an IDE](18_cli.vibe.md).

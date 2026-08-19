# 11 — Concurrency

日本語版: [11_concurrency.vibe.md](../ja/11_concurrency.vibe.md)

vibe's public concurrency model is **shared-nothing structured
concurrency** (ADR-0068). You do not spawn OS threads. You run a
`TaskGroup`, spawn work into it, and join.

The package is `@vibe/concurrent`.

## What is checked

`TaskGroup::run` creates a fresh region. If the body's **return value**
carries a `TaskGroup` / `TaskHandle` / `Sender` / `Receiver` from that
region, the compiler rejects the program.

`TaskGroup::spawn` / `::spawn_suspend` enforce `Spawnable` — same-region
or `Send` captures — when the callee is spelled **literally**. A renamed
import or `let spawn = TaskGroup::spawn` bypasses that check. `adopt` /
`settle` are out of scope today.

```vibe skip
// skip: contract sketch — see lib/@vibe/concurrent and fixtures/region_ok_basic.vibe
import @vibe/concurrent {
  TaskGroup, TaskHandle
}

fn main with Exception {
  let answer = TaskGroup::run((n) -> {
    let h = TaskGroup::spawn(n, () -> {
      21 * 2
    })
    TaskHandle::join(h)
  })
  // answer == 42
}
```

`Send` is judged structurally. Scalars, tuples, `Option` of Send parts,
and `mut`-field-free structs/enums made of Send parts may cross a
spawn. `Array` / `Bytes`, closures, and `mut`-field structs may not.
`FrozenArray[T]` exists specifically as the Send-eligible array. A
persistent `Map` is *not* automatically `Send`.

## Suspend vs blocking

`sleep` blocks the whole instance. `sleep_wait` parks the task so siblings
can run. Channel `send` / `recv` on the stack-driving API block the
scheduler thread of control; `send_wait` / `recv_wait` suspend.

The `Async` effect on this package is `Suspend(Int) -> Int`. That is a
library effect, not a language keyword.

## Shared-nothing

Messages are values. The long-term semantics are a deep-copy snapshot
across tasks. Today everything still shares one heap: send immutable
data. Multithreading, when it lands, stays shared-nothing
(`TaskGroup` + `Send` / region checks already describe that shape).

Next: [The CLI as an IDE](12_cli.vibe.md).

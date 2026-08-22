# 13 — Collections

Previous: [Writing tests](12_tests.vibe.md)

日本語版: [13_collections.vibe.md](../ja/13_collections.vibe.md)

Arrays, builders, and maps. vibe also has a naming rule that tells you
which of them mutate, and you will be able to read it off the names by
the end of this chapter.

## Arrays

`Array` is the primitive sequence: index it, map over it, push to it.

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  println("xs[0] = \{xs[0]}")
  println("length = \{Array::length(xs)}")
  let doubled = Array::map(xs, _ * 2)
  println("doubled[2] = \{Array::get(doubled, 2)}")
  Array::push(xs, 4)
  println("after push, length = \{Array::length(xs)}")
}
```

```output
xs[0] = 1
length = 3
doubled[2] = 6
after push, length = 4
```

The one thing to remember: `Array::push` grows the receiver **in place**,
so every alias of that array sees the new length. An `Array` is a mutable
handle, not a value.

`xs[i]` and `Array::get(xs, i)` are the same read. Out of range, both
**trap** — the program stops rather than answering with a sentinel
(#2199 tracks making the trap say so). When "maybe absent" is the
normal case, that is what `Option`-returning lookups like `MutMap::get`
below are for.

## Building one

When you fill a collection once and then only read it, build it and
freeze it. `ArrayBuilder::freeze` hands back an ordinary `Array`.

```vibe run
fn main with Console {
  let b = ArrayBuilder::new()
  ArrayBuilder::push(b, 10)
  ArrayBuilder::push(b, 20)
  let xs = ArrayBuilder::freeze(b)
  println("built length = \{Array::length(xs)}, [0] = \{xs[0]}")
}
```

```output
built length = 2, [0] = 10
```

Strings work the same way, and here it matters for a different reason:
assembling a string with repeated concatenation is quadratic, while a
builder is linear.

```vibe run
fn main with Console {
  let b = StringBuilder::new()
  StringBuilder::push(b, "hello ")
  StringBuilder::push(b, "vibe")
  println(StringBuilder::build(b))
}
```

```output
hello vibe
```

## Maps

`MutMap` is the general-purpose map, from `@vibe/core`. `::new_string`
and `::new_int` pick a key specialization, so the common cases need no
hash or equality closure from you.

```vibe run
import @vibe/core { struct MutMap }

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn main with Console {
  let m: MutMap[String, Int] = MutMap::new_string()
  MutMap::set(m, "a", 1)
  MutMap::set(m, "b", 2)
  MutMap::set(m, "a", 7)
  println("size = \{MutMap::size(m)}")
  println("a = \{unwrap_or(MutMap::get(m, "a"), -1)}")
  println("z = \{unwrap_or(MutMap::get(m, "z"), -1)}")
}
```

```output
size = 2
a = 7
z = -1
```

`get` returns `Option`, so a missing key is a value you handle rather
than a crash or a zero. Setting a key that already exists replaces it —
`"a"` was set twice and the size stayed 2.

## Reading mutability off the name

You have now used three of the four shapes. The rule behind them:

| spelling | meaning | examples |
|---|---|---|
| bare | persistent — an "update" returns a new value | `Map` |
| `Mut-` prefix | in-place handle | `MutMap`, `MutSet` |
| `-Builder` suffix | throwaway grower; finish it, then stop holding it | `ArrayBuilder`, `StringBuilder` |
| `Frozen-` prefix | immutable *and* allowed to cross a task boundary | `FrozenArray[T]` |

Persistent and `Frozen` are different questions. Persistent is about what
an update does; `Frozen` is about whether the value is `Send` — see
[Concurrency](17_concurrency.vibe.md).

Builders finish with `::build` for `StringBuilder`, `::freeze` for
`ArrayBuilder` and `MapBuilder`.

`Array` and `Bytes` are older than this rule and stay low-level mutable
primitives. Their operations mean the same thing on every backend.

## Which map

Reach for `MutMap`. `Map` without a prefix is a small assoc list with
O(n) lookup — fine for a handful of keys, wrong for anything hot. For a
persistent map you intend to grow, use `MapHamt` from `@vibex/immut`.

If you meet `HashMap` in older code it is a transparent alias of
`MutMap`; `vibe check` warns on the old function names.

Next: [Iteration](14_iteration.vibe.md).

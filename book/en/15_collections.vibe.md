# 15 — Collections

日本語版: [15_collections.vibe.md](../ja/15_collections.vibe.md)

vibe names a collection so you can read its mutability off the spelling.

- A **bare** name is persistent: every "mutating" operation returns a new
  value (`Map`, conceptually `Set`).
- A **`Mut-` prefix** is an in-place handle (`MutMap`, `MutSet`).
- An **`XBuilder` suffix** is a throwaway grower. Finish it and stop
  holding it. `StringBuilder` ends with `::build`. `ArrayBuilder` /
  `MapBuilder` still end with `::freeze` (the `build` verb is the planned
  one).
- A **`Frozen-` prefix** is immutable *and* `Send`-eligible
  (`FrozenArray[T]`). Persistent is not the same as Frozen.

`Array` and `Bytes` predate the rule and stay low-level mutable
primitives. Their operations have the same meaning on linear, RC, and
wasm-gc.

## `Array`

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

`Array::push` grows the receiver **in place**. Every alias of that array
sees the new length. Prefer `ArrayBuilder` when you accumulate once and
then only read.

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

## `StringBuilder`

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

## `MutMap`

General-purpose maps live in `@vibe/core`. `MutMap::new_string` /
`::new_int` pick a key specialization so you do not pass hash/eq
closures for the common cases.

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

The old `HashMap` name is a transparent alias of `MutMap`. New code
writes `MutMap`. `vibe check` warns on the old function names.

`Map` (no prefix) is a small assoc list. For a persistent map that you
will grow, use `MapHamt` from `@vibex/immut` — `Map` is O(n) per lookup
and has burned the compiler itself.

Next: [Mutation](09_mutation.vibe.md).

# 15 — コレクション

English version: [11_collections.vibe.md](../en/11_collections.vibe.md) (canonical)

vibe は、綴りから可変性が読めるようにコレクションを命名している。

- **裸の名前**は永続的で、「変更」操作はすべて新しい値を返す
  (`Map`、概念的には `Set`)。
- **`Mut-` 接頭辞**は in-place なハンドル (`MutMap`、`MutSet`)。
- **`XBuilder` 接尾辞**は使い捨ての growth 用。作り終えたら手放すこと。
  `StringBuilder` は `::build` で終わる。`ArrayBuilder` / `MapBuilder` は
  まだ `::freeze` で終わる (`build` という動詞に寄せる予定)。
- **`Frozen-` 接頭辞**は immutable **かつ** `Send` 可能 (`FrozenArray[T]`)。
  永続的であることと Frozen であることは別。

`Array` と `Bytes` はこの規則より前からあり、低レベルな可変プリミティブの
ままにしてある。これらの操作は linear・RC・wasm-gc のどれでも同じ意味を持つ。

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

`Array::push` はレシーバを**その場で**伸ばす。その配列のすべての別名が
新しい長さを見る。一度溜めてあとは読むだけなら `ArrayBuilder` を選ぶこと。

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

汎用のマップは `@vibe/core` にある。`MutMap::new_string` / `::new_int` は
キーの特殊化を選ぶので、よくあるケースで hash/eq のクロージャを渡さずに済む。

```vibe run
import @vibe/core {
  type MutMap, MutMap::get, MutMap::new_string, MutMap::set, MutMap::size
}

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

古い `HashMap` という名前は `MutMap` の透過的な別名。新しいコードでは
`MutMap` と書く。古い関数名には `vibe check` が警告する。

`Map` (接頭辞なし) は小さな連想リスト。伸ばしていく永続マップが欲しい
なら `@vibex/immut` の `MapHamt` を使うこと — `Map` は lookup が O(n) で、
コンパイラ自身がそれで焼かれたことがある。

次章: [ミューテーション](06_mutation.vibe.md)。

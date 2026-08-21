# 11 — コレクション

前: [テストを書く](10_tests.vibe.md)

English version: [11_collections.vibe.md](../en/11_collections.vibe.md)

配列とビルダーとマップ。vibe には「どれが変更されるか」を名前から読める
命名規則もあり、この章の終わりには名前を見ただけで判断できるようになる。

## 配列

`Array` は基本の列。添字で読み、map をかけ、push する。

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

覚えることは一つ。`Array::push` はレシーバを**その場で**伸ばすので、その
配列の別名すべてが新しい長さを見る。`Array` は値ではなく可変のハンドル。

## 組み立てる

一度詰めたあとは読むだけ、という場合はビルダーで作って freeze する。
`ArrayBuilder::freeze` が返すのは普通の `Array`。

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

文字列も同じ形だが、理由が違う。連結を繰り返して文字列を組み立てると
O(n²) になり、ビルダーなら線形で済む。

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

## マップ

汎用のマップは `@vibe/core` の `MutMap`。`::new_string` と `::new_int` が
キーの特殊化を選ぶので、よくある場合にハッシュや等価判定のクロージャを
渡す必要はない。

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

`get` は `Option` を返すので、キーが無い場合はクラッシュでもゼロでもなく
「扱う値」になる。既にあるキーへの `set` は置き換え — `"a"` は二度 set
したがサイズは 2 のまま。

## 名前から可変性を読む

ここまでで4つの形のうち3つを使った。その規則:

| 綴り | 意味 | 例 |
|---|---|---|
| 裸 | 永続的 — 「更新」は新しい値を返す | `Map` |
| `Mut-` 接頭辞 | in-place なハンドル | `MutMap`, `MutSet` |
| `-Builder` 接尾辞 | 使い捨ての growth 用。作り終えたら手放す | `ArrayBuilder`, `StringBuilder` |
| `Frozen-` 接頭辞 | immutable **かつ** タスク境界を越えられる | `FrozenArray[T]` |

永続的であることと `Frozen` であることは別の問いを指す。永続的とは更新の
振る舞いのことで、`Frozen` はその値が `Send` かどうか —
[並行性](17_concurrency.vibe.md) を参照。

ビルダーの終端は `StringBuilder` が `::build`、`ArrayBuilder` と
`MapBuilder` が `::freeze`。

`Array` と `Bytes` はこの規則より前からあり、低レベルな可変プリミティブの
ままにしてある。これらの操作はどのバックエンドでも同じ意味を持つ。

## どのマップを使うか

まず `MutMap`。接頭辞の無い `Map` は小さな連想リストで、探索が O(n) —
キーが数個なら十分だが、ホットな場所では誤り。育てる前提の永続マップが
要るなら `@vibex/immut` の `MapHamt` を使う。

古いコードで `HashMap` に出会ったら、それは `MutMap` の透過的な別名。
古い関数名には `vibe check` が警告する。

次: [反復](12_iteration.vibe.md)。

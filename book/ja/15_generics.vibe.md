# 16 — ジェネリクス・trait・derive

English version: [15_generics.vibe.md](../en/15_generics.vibe.md) (canonical)

型パラメータは `[T]`、境界は `[T: Eq + Ord]` と書く。同じ `+` が row の
effect 名も繋ぐ (`with Exception + Fs`) ので、カンマが 2 つの意味を持つ
必要はない。

## ジェネリックな関数と struct

トップレベルの `fn` には完全な注釈が要る。struct リテラルの型引数は
フィールドから推論するか、`Box[Int]::{ ... }` で明示できる。

```vibe run
struct Box[T] {
  v: T
}

fn identity[T](x: T) -> T {
  x
}

fn main with Console {
  let b = Box::{
    v: 41
  }
  println("id = \{identity(b.v + 1)}")
}
```

```output
id = 42
```

## `derive`

`derive (Eq, Ord, Show, Hash, Default)` が、struct や enum に期待される
操作を得る通常の手段。`Eq` はマーカーで、構造的な `==` が `T::equals`
として生成される。`Ord` は `T::compare -> Int` (`-1` / `0` / `1`) を与える。
`Show` は `T::to_string` を与え、文字列補間もこれを使う。

```vibe run
enum Color {
  Red; Green; Blue
} derive (Eq, Show)

fn main with Console {
  println("eq = \{Color::Red == Color::Red}")
  println("neq = \{Color::Red == Color::Blue}")
  println("show = \{Color::Green}")
}
```

```output
eq = true
neq = false
show = Green
```

## 自分で書く trait

メソッドを持たないマーカー trait は、`Eq` のようにコンパイラが既に理解して
いる境界のためのもの。メソッドを持つ trait は witness 辞書を運ぶので、
ユーザーコードで欲しいのはこちら。`Array` / `Bytes` へのマーカー `impl` は
`[T: Eq]` を**満たさない** — 要素型が消去されており、`==` が黙って
参照等価になってしまうため。

```vibe run
trait Measured {
  measure(Self) -> Int
}

impl [T] Measured for Array[T] {
  measure(self) -> Int {
    Array::length(self)
  }
}

fn size_of[T: Measured](x: T) -> Int {
  T::measure(x)
}

fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  println("size_of = \{size_of(xs)}")
}
```

```output
size_of = 3
```

`Send` はユーザー trait ではない。コンパイラが構造的に判定する
(プリミティブ、タプル、Send な要素の `Option`、immutable な struct / enum)。
`impl Send for X` はエラー。[並行処理](17_concurrency.vibe.md) を参照。

`Default` は builtin。ジェネリックなコードから `T::default()` を呼ぶ必要が
あれば `import @vibe/core { Default }`。`derive(Default)` が impl を登録する。

次章: [反復](12_iteration.vibe.md)。

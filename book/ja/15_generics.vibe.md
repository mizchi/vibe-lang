# 15 — ジェネリクス・trait・derive

前: [反復](14_iteration.vibe.md)

English version: [15_generics.vibe.md](../en/15_generics.vibe.md)

同じ関数を型ごとに書き直す — それがジェネリクスの解く問題です。型引数は
`[T]` に、その制約は `[T: Eq]` に書きます。

## 定義は一つ、型は多数

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

`identity` はどんな `T` でも動きます。`Box[T]` もどんな `T` でも持て、上の
リテラルはどの型かを書いていません — `v: 41` から推論されました。推論の
手がかりが無いときは `Box[Int]::{ ... }` と明示します。

トップレベルの `fn` は、ジェネリックかどうかに関わらず引数と戻り値を
完全に注釈します。推論が埋めるのは呼び出し側であって、宣言側ではありません。

## `derive` が定番の操作をくれる

たいていの型は等価性・順序・表示可能な形を欲しがります。それを要求します。

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

`derive (Eq, Ord, Show, Hash, Default)` の5つです。`Eq` はその型の `==` を
構造的にし、`Ord` は `-1` / `0` / `1` を返す `T::compare` を与え、`Show` は
`T::to_string` を与えます。文字列補間が呼ぶのもこれです。

## 自分で書く trait

メソッドを持つ trait は契約で、それを境界にするというのは「呼び出し側が
実装を渡す」という意味になります。

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

`size_of` は `T` が何かを知りません。`T::measure` は呼び出し側が供給する
witness を通って実装に届きます。境界が実際に動く呼び出しになるのはこの
仕組みによります。

その witness が限界でもあります。`[T: Eq]` のような境界は witness を要求し、
要素型が消去されたコンテナはそれを持ちません。だから
`fn eq2[T: Eq](a: T, b: T)` に `Array[Int]` を渡すと**拒否されます**。

```
no impl `Eq` for `Array[Int]`
```

コンパイル時に知らされます。続きは[等価性](16_equality.vibe.md)にあります。

## 自分では実装しない2つ

`Send` はコンパイラが構造的に判定します — プリミティブ、タプル、`Send` な
部品の `Option`、不変な struct と enum。なので `impl Send for X` は約束の
手段ではなくエラーです。[並行性](17_concurrency.vibe.md) を参照。

`Default` は組み込みで、`derive(Default)` が実装を登録します。`T::default()`
を呼ぶジェネリックなコードには `import @vibe/core { Default }` が要ります。

次: [等価性](16_equality.vibe.md)。

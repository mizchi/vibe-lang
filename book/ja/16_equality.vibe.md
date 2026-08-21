# 16 — 等価性

前: [ジェネリクス・trait・derive](15_generics.vibe.md)

English version: [16_equality.vibe.md](../en/16_equality.vibe.md) (canonical)

`==` は値で比較する。内容の等しい配列どうしは等しく、フィールドの等しい
struct どうしは等しい。黙ってアドレスを比べる経路は無い。

境界はちょうど一つあり、それは誤った答えではなくコンパイルエラーになる —
章の最後を参照。

## すでに値で比較されるもの

スカラー、タプル、`derive(Eq)` の付いた struct / enum、`Bytes` (内容比較)、
そして要素型が分かっているときの `Array[T]`。

```vibe run
struct Point {
  x: Int; y: Int
} derive (Eq)

fn same_ints(a: Array[Int], b: Array[Int]) -> Bool {
  a == b
}

fn main with Console {
  println("lits = \{[1, 2] == [1, 2]}")
  let a = [
    1,
    2
  ]
  let b = [
    1,
    2
  ]
  println("lets = \{a == b}")
  println("fn   = \{same_ints(a, b)}")
  println("tuple = \{([1, 2], 0) == ([1, 2], 0)}")
  println("struct = \{Point::{ x: 1, y: 2 } == Point::{ x: 1, y: 2 }}")
}
```

```output
lits = true
lets = true
fn   = true
tuple = true
struct = true
```

`Bytes` も内容比較で、タプルの要素や `derive(Eq)` のフィールドとして
使ったときも同じ。

## 例外だと思われがちなもの

要素がスカラーでない配列も、関数の戻り値として来た配列も、空から始めた
配列も、値で比較される。最後のものは実際に走らせる価値がある — 空の配列
2つの片方に push しても、古い答えではなく正しい答えが返る。

```vibe run
fn mk() -> Array[Int] {
  [
    1,
    2
  ]
}

fn main with Console {
  let pairs: Array[(Int, Int)] = [(1, 2)]
  let same: Array[(Int, Int)] = [(1, 2)]
  let other: Array[(Int, Int)] = [(1, 3)]
  println("non-scalar elements = \{pairs == same}, differ = \{pairs == other}")
  println("function returns    = \{mk() == mk()}")
  let xs: Array[Int] = []
  let ys: Array[Int] = []
  println("empty and empty     = \{xs == ys}")
  Array::push(xs, 1)
  println("after one push      = \{xs == ys}")
  Array::push(ys, 1)
  println("after both          = \{xs == ys}")
}
```

```output
non-scalar elements = true, differ = false
function returns    = true
empty and empty     = true
after one push      = false
after both          = true
```

空リテラルには上の `xs` / `ys` のように注釈を付けること。注釈の無い
`let xs = []` には比較の基準になる要素型が無い。この形の束縛どうしは、
両方が空のままなら等しく比較されるが、片方に push してから比較すると
答えを返さず**実行時に trap する** (#2157)。注釈がその対処であり、この章が
注釈を求める理由はそれだけ。

## 唯一の境界: witness を持たない generic な `T`

`fn f[T: Eq](a: T, b: T)` の内側では、コード生成の時点で要素型が消えて
いるので、`==` には呼び出し側が渡す `Eq` の witness が答える。witness を
持つ型なら、そのまま構造的な答えになる:

```vibe run
fn eq2[T: Eq](a: T, b: T) -> Bool {
  a == b
}

fn main with Console {
  println("Int    same = \{eq2(1, 1)}, differ = \{eq2(1, 2)}")
  println("String same = \{eq2("x", "x")}, differ = \{eq2("x", "y")}")
}
```

```output
Int    same = true, differ = false
String same = true, differ = false
```

`Eq` の witness を持たない型なら渡すものが無いので、その呼び出しは
**拒否される**:

```vibe skip
// skip: これはコンパイルエラー。出るメッセージを見せるための例
fn eq2[T: Eq](a: T, b: T) -> Bool { a == b }

fn main with Console {
  println("\{eq2([1], [1])}")
}
```

```
no impl `Eq` for `Array[Int]`
```

以上が全部。コンパイル時に知らされるので、アドレスで黙って答える比較を
踏むことはない。

次: [並行処理](17_concurrency.vibe.md)。

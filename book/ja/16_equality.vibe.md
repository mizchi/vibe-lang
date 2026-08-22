# 16 — 等価性

前: [ジェネリクス・trait・derive](15_generics.vibe.md)

English version: [16_equality.vibe.md](../en/16_equality.vibe.md) (canonical)

`==` は値で比較する。内容の等しい配列どうしは等しく、フィールドの等しい
struct どうしは等しい。黙ってアドレスを比べる経路は無い。

知っておく価値のある縁が1つある。こちらも誤った答えは返さない。`Eq` の
witness を持たない generic な `T` は**コンパイルエラー**になる。以下で扱う。

## ふつうの場合

スカラー、タプル、`derive(Eq)` の付いた struct と enum、内容で比較される
`Bytes`、そして配列。

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
  let us = []
  let vs = []
  Array::push(us, 1)
  Array::push(vs, 2)
  println("no annotation       = \{us == vs}")
}
```

```output
non-scalar elements = true, differ = false
function returns    = true
empty and empty     = true
after one push      = false
after both          = true
no annotation       = false
```

`us` と `vs` には注釈が無いが、それでも内容で比較される。注釈の無い
`let xs = []` は、それを埋める `Array::push` から要素型を受け取る
(#2157) — ただし push する値が自分で型を語る場合に限る。リテラルはそうで、
リテラルだけからなる配列・tuple・struct や、両分岐が一致する `if` も同じ。

代わりに**名前**や**呼び出しの結果**を push すると、その束縛には要素型が
付かない。両側とも非空になった状態で比較すると、アドレスや長さで答えるのでは
なく**実行時に失敗する**。注釈がその解決策で、上の `xs` / `ys` が注釈を
持っているのはそのためである。

## コンパイル時の縁: witness を持たない generic な `T`

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

以上が全部。2つの縁のどちらでも必ず知らされる — witness が無い場合は
コンパイル時に、注釈の無い空配列はトラップで。どちらもアドレスで黙って
答えることはない。

次: [並行処理](17_concurrency.vibe.md)。

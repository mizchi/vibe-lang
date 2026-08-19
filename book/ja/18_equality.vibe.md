# 18 — 等価性

English version: [18_equality.vibe.md](../en/18_equality.vibe.md) (canonical)

`==` はどの文脈でも構造的等価を意味することになっている (ADR-0097)。
表面のほとんどは既にそうなっている。まだ参照で比較する経路がいくつか
残っているので、「黙って誤った答え」として自分で踏んで発見せずに済むよう、
末尾に列挙する。

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

## 空配列には要素型が要る

`let xs = []` は要素型を決めない。この形の束縛どうしは、空のままなら
等しく比較される。あとから push してから比較すると、コンパイラは黙って
参照等価に落ちることを拒否する — `let xs: Array[Int] = []` と注釈すること。

## まだ参照等価のもの

- 消去された型変数 (`[T: Eq]` の `T`) — `==` を書き換える先の要素型が
  残っていない。
- 型が付かないまま来た一部の関数戻り値経路と空リテラル束縛。
- 要素型がスカラーでない、名前経由の配列。

迷ったら意図した比較を自分で書くこと (`Array::length` とループ、あるいは
自分が管理する `derive(Eq)` 型)。ジェネリックな `T` の `==` が構造的だと
仮定しないこと。

次章: [小さなプログラム](19_a_small_program.vibe.md)。

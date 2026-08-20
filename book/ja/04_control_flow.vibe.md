# 04 — 制御フロー

前: [値と関数](03_values_functions.vibe.md)

English version: [04_control_flow.vibe.md](../en/04_control_flow.vibe.md)

ここに出てくるものはすべて式です。`if` は値を作り、ループも値を作ります。
早めに慣れておく価値があります — 他の言語で可変変数が必要になる理由の
ほとんどが、これで消えるからです。

## `if`

```vibe run
fn main with Console {
  let v = if 1 < 2 {
    "yes"
  } else {
    "no"
  }
  println("v = \{v}")
}
```

```output
v = yes
```

`if` 全体が1つの値なので、両方の枝は同じ型を作る必要があります。

## `while` と `return`

`while` は見慣れたループです。`return` はループではなく**関数**を抜けます。
探索ではそれが欲しい挙動です:

```vibe run
fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 {
      return i
    }
    i = i + 1
  }
  return -1
}

fn main with Console {
  println("find_first_neg([3, 1, -2, 5]) = \{find_first_neg([3, 1, -2, 5])}")
  println("find_first_neg([1, 2]) = \{find_first_neg([1, 2])}")
}
```

```output
find_first_neg([3, 1, -2, 5]) = 2
find_first_neg([1, 2]) = -1
```

## `loop` — 値を持ち回るループ

`while` には可変なカウンタが要ります。`loop` には要りません。パラメータを
宣言し、`continue` が次の周の値を渡し、`break` が結果とともに終わらせます。

```vibe run
fn main with Console {
  let sum = loop (i = 0, acc = 0) {
    if i >= 10 {
      break acc
    }
    continue (i + 1, acc + i)
  }
  println("sum = \{sum}")
}
```

```output
sum = 45
```

覚える規則はこれだけです: **`continue` はループのパラメータ1つにつき値を
1つ、`break` は結果を1つ取ります。** 引数なしの `continue` は全部そのままで
もう一周します。`continue` に渡す個数を間違えると、コンパイラが両方の個数を
挙げて指摘します。

`break` が取るのは単一の結果なので、2つ返したければタプルを返します:

```vibe run
fn main with Console {
  let r = loop (i = 0, acc = 0) {
    if i >= 3 {
      break (acc, i)
    }
    continue (i + 1, acc + i)
  }
  println("r = (\{r.0}, \{r.1})")
}
```

```output
r = (3, 3)
```

## `for ... in` は集める

`for-in` も式で、本体の結果を集めた `Array` に評価されます。要素の前に
名前を足すと添字が取れます:

```vibe run
fn main with Console {
  let doubled = for x in [
    1,
    2,
    3
  ] {
    x * 2
  }
  let with_index = for i, x in [
    10,
    20
  ] {
    i + x
  }
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("with_index = [\{Array::get(with_index, 0)}, \{Array::get(with_index, 1)}]")
}
```

```output
doubled = [2, 4, 6]
with_index = [10, 21]
```

## `|>`

`x |> f` は `f(x)` です。変換を内側から外側へではなく、左から右へ読ませます:

```vibe run
fn pair(a: Int, b: Int) -> Int {
  a * 10 + b
}

fn main with Console {
  let trimmed_len = "  hi  " |> String::trim |> String::length
  let arr_len = [
    1,
    2,
    3
  ] |> Array::length
  let mapped = [
    1,
    2,
    3
  ] |> Array::map(_, _ * 2)
  let repeated = 7 |> pair(_, _)
  println("trimmed_len = \{trimmed_len}")
  println("arr_len = \{arr_len}")
  println("mapped = [\{Array::get(mapped, 0)}, \{Array::get(mapped, 1)}, \{Array::get(mapped, 2)}]")
  println("repeated = \{repeated}")
}
```

```output
trimmed_len = 2
arr_len = 3
mapped = [2, 4, 6]
repeated = 77
```

既定では、渡された値は第1引数になります。別の位置に入れたいときは裸の `_` で
場所を指定します — `x |> f(a, _)` は `f(a, x)` で、スロットは繰り返せるので
`7 |> pair(_, _)` は `pair(7, 7)` です。

もっと大きな式の中の `_` は別物で、前章のラムダ略記です。だから
`Array::map(_, _ * 2)` には無関係な仕事をする `_` が2つあります — 最初が
パイプのスロット、次が `(v) -> v * 2` です。

次: [型と文字列](05_types_strings.vibe.md)

# 02 — 制御フロー

前章: [01 値と関数](01_values_functions.vibe.md)

## if は式

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let v = if 1 < 2 {
    "yes"
  } else {
    "no"
  }
  stdout_write("v = \{v}\n")
}
```

```output
v = yes
```

## while と早期 return（現行）

`return` は関数全体から抜ける (ループだけではない)。これは現行構文であり、
維持するか代替構文へ移行するかは [#1283](https://github.com/mizchi/vibe-lang/issues/1283) で決める。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 {
      return i
    }
    i = i + 1
  }
  // 早期 return (`return i`) と関数末尾の暗黙の戻り値は同じ「関数の結果」
  // なので、ここも揃えて `return -1` と明示している (裸の `-1` を関数
  // 本体の最後の式として置くのも動作は同じ -- while ブロックは Unit の
  // 文として閉じるので `-1` は独立した最終式になる)。
  return -1
}

fn main with { Stdout } {
  stdout_write("find_first_neg([3, 1, -2, 5]) = \{find_first_neg([3, 1, -2, 5])}\n")
  stdout_write("find_first_neg([1, 2]) = \{find_first_neg([1, 2])}\n")
}
```

```output
find_first_neg([3, 1, -2, 5]) = 2
find_first_neg([1, 2]) = -1
```

## loop — パラメータ付き末尾再帰

`loop (引数 = 初期値, ...)` + `continue(次の値...)` + `break 結果`。
可変変数なしで畳み込みが書ける。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let sum = loop (i = 0, acc = 0) {
    if i >= 10 {
      break acc
    }
    continue (i + 1, acc + i)
  }
  stdout_write("sum = \{sum}\n")
}
```

```output
sum = 45
```

`continue(...)` と `break ...` は見た目が似ているが対称ではない。この学習コストを
解消する構文方針は [#1284](https://github.com/mizchi/vibe-lang/issues/1284) で追跡する。
`continue(a, b)` はループの次の状態 (`i`, `acc`, ... それぞれ 1 つずつ)
への関数呼び出しのような構文だが、`break(a, b)` の丸括弧はただの式の括弧
— `break` に `(a, b)` という**タプル 1 個**を渡しているだけ (`break a, b`
のような「2 値の loop 結果」にはならない)。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let r = loop (i = 0, acc = 0) {
    if i >= 3 {
      break (acc, i)
    }
    // break(acc, i) は tuple (acc, i)
    continue (i + 1, acc + i)
  }
  stdout_write("r = (\{r.0}, \{r.1})\n")
  // r: (Int, Int) -- break acc, i ではない
}
```

```output
r = (3, 3)
```

## for-in は Array を返す

```vibe run
import @vibe/prelude {
  stdout_write
}

fn main with { Stdout } {
  let doubled = for x in [
    1,
    2,
    3
  ] {
    x * 2
  }
  // [2, 4, 6]
  let with_index = for i, x in [
    10,
    20
  ] {
    i + x
  }
  // [10, 21]
  stdout_write("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]\n")
  stdout_write("with_index = [\{Array::get(with_index, 0)}, \{Array::get(with_index, 1)}]\n")
}
```

```output
doubled = [2, 4, 6]
with_index = [10, 21]
```

## パイプ演算子

`x |> f` は `f(x)`。call 内に**裸の** `_` がなければ、値は第 1 引数に入る。
裸の `_` は pipe slot で、その位置に値を置く (`x |> f(a, _)` は `f(a, x)`)。
同じ slot を繰り返してよく、`x |> f(_, _)` は `f(x, x)` になる。

`_ * 2` のように `_` を含む**複合式**は slot ではなく section ラムダ
(`(v) -> v * 2`)。従って `xs |> Array::map(_, _ * 2)` は
`Array::map(xs, (v) -> v * 2)` と読む。この `_` の二つの役割を混同しない。

ユーザー定義の `Type::method` は `value.method(...)` と入力できるが、チュートリアル
では常に `Type::method(value, ...)` を正規形として書く。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn pair(a: Int, b: Int) -> Int {
  a * 10 + b
}

fn main with { Stdout } {
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
  stdout_write("trimmed_len = \{trimmed_len}\n")
  stdout_write("arr_len = \{arr_len}\n")
  stdout_write("mapped = [\{Array::get(mapped, 0)}, \{Array::get(mapped, 1)}, \{Array::get(mapped, 2)}]\n")
  stdout_write("repeated = \{repeated}\n")
}
```

```output
trimmed_len = 2
arr_len = 3
mapped = [2, 4, 6]
repeated = 77
```

次章: [03 データ](03_data.vibe.md)

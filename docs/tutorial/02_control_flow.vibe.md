# 02 — 制御フロー

前章: [01 値と関数](01_values_functions.vibe.md)

## if は式

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let v = if 1 < 2 { "yes" } else { "no" }
  stdout_write("v = \{v}\n")
}
```

```output
v = yes
```

## while と早期 return

`return` は関数全体から抜ける (ループだけではない)。

```vibe run
import @vibe/prelude { stdout_write }

fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 { return i }
    i = i + 1
  }
  // ここは while の直後で関数本体の「最後の文」なので、裸の `-1` を
  // 置いても正しく動く (while ブロックは Unit の文として閉じ、`-1` が
  // 独立した最終式になる)。それでも `return -1` と明示するのは、
  // 「途中の文」と「最後の式」の境目を読み手に一目で分からせるため --
  // 関数本体の途中 (=最後の文ではない位置) に non-Unit な式を裸で置くと
  // (数値リテラル単体・裸の変数参照など)、型検査は通過するのに codegen が
  // 壊れた wasm を生成する既知バグがある (#1203: スタックに値が捨てられず
  // 残る)。`vibe check` は素通りし `vibe run` で初めて落ちるので、途中の
  // 式は `let _ = expr` で明示的に捨てるか、値として使うのが安全。
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
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let sum = loop (i = 0, acc = 0) {
    if i >= 10 { break acc }
    continue(i + 1, acc + i)
  }
  stdout_write("sum = \{sum}\n")
}
```

```output
sum = 45
```

`continue(...)` と `break ...` は見た目が似ているが対称ではない。
`continue(a, b)` はループの次の状態 (`i`, `acc`, ... それぞれ 1 つずつ)
への関数呼び出しのような構文だが、`break(a, b)` の丸括弧はただの式の括弧
— `break` に `(a, b)` という**タプル 1 個**を渡しているだけ (`break a, b`
のような「2 値の loop 結果」にはならない)。

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let r = loop (i = 0, acc = 0) {
    if i >= 3 { break(acc, i) }        // break(acc, i) は tuple (acc, i)
    continue(i + 1, acc + i)
  }
  stdout_write("r = (\{r.0}, \{r.1})\n")   // r: (Int, Int) -- break acc, i ではない
}
```

```output
r = (3, 3)
```

## for-in は Array を返す

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let doubled = for x in [1, 2, 3] { x * 2 }        // [2, 4, 6]
  let with_index = for i, x in [10, 20] { i + x }   // [10, 21]
  stdout_write("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]\n")
  stdout_write("with_index = [\{Array::get(with_index, 0)}, \{Array::get(with_index, 1)}]\n")
}
```

```output
doubled = [2, 4, 6]
with_index = [10, 21]
```

## パイプ演算子

`x |> f` は `f(x)`。値は既定で第 1 引数に入り、`_` で位置を指定できる。
`_ * 2` のような複合プレースホルダは section ラムダになる。

```vibe run
import @vibe/prelude { stdout_write }

fn main with { Stdout } {
  let trimmed_len = "  hi  " |> String::trim |> String::length
  let arr_len = [1, 2, 3] |> Array::length
  let mapped = [1, 2, 3] |> Array::map(_, _ * 2)
  stdout_write("trimmed_len = \{trimmed_len}\n")
  stdout_write("arr_len = \{arr_len}\n")
  stdout_write("mapped = [\{Array::get(mapped, 0)}, \{Array::get(mapped, 1)}, \{Array::get(mapped, 2)}]\n")
}
```

```output
trimmed_len = 2
arr_len = 3
mapped = [2, 4, 6]
```

次章: [03 データ](03_data.vibe.md)

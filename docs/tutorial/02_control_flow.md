# 02 — 制御フロー

実行: `vibe test docs/tutorial/02_control_flow_test.vibe`

## if は式

```vibe
let v = if 1 < 2 { "yes" } else { "no" }
```

## while と早期 return

`return` は関数全体から抜ける (ループだけではない)。

```vibe
fn find_first_neg(arr: Array[Int]) -> Int {
  let mut i = 0
  while i < Array::length(arr) {
    if Array::get(arr, i) < 0 { return i }
    i = i + 1
  }
  // 落とし穴: ブロックの直後に裸の `-1` を置くと二項マイナスに読まれる。
  // 末尾の負値は `return -1` と書く。
  return -1
}
```

## loop — パラメータ付き末尾再帰

`loop (引数 = 初期値, ...)` + `continue(次の値...)` + `break 結果`。
可変変数なしで畳み込みが書ける。

```vibe
let sum = loop (i = 0, acc = 0) {
  if i >= 10 { break acc }
  continue(i + 1, acc + i)
}
// sum == 45
```

## for-in は Array を返す

```vibe
let doubled = for x in [1, 2, 3] { x * 2 }        // [2, 4, 6]
let with_index = for i, x in [10, 20] { i + x }   // [10, 21]
```

## パイプ演算子

`x |> f` は `f(x)`。値は既定で第 1 引数に入り、`_` で位置を指定できる。
`_ * 2` のような複合プレースホルダは section ラムダになる。

```vibe
"  hi  " |> String::trim |> String::length   // 2
[1, 2, 3] |> Array::length                   // 3
[1, 2, 3] |> Array::map(_, _ * 2)            // [2, 4, 6]
```

次章: [03 データ](03_data.md)

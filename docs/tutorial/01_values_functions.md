# 01 — 値と関数

実行: `vibe test docs/tutorial/01_values_functions_test.vibe`
(この章の例文はすべて [01_values_functions_test.vibe](01_values_functions_test.vibe) にある)

## 値と基本型

束縛は `let`。型注釈は省略できる (推論される)。

```vibe
let x: Int = 42          // 62-bit tagged。リテラル上限 2^61-1
let d: Double = 3.14     // 64-bit float (小数点リテラルの既定)
let b: Bool = true
let s = "answer \{x}"    // 文字列補間は \{expr}
let c = 'A'              // char リテラルは文字コード (Int)。'A' == 65
```

注意: 文字列の添字 `s[i]` は **文字コード (Int)** を返す。1 文字の String が
欲しいときは `String::from_char_code(s[i])` か slice を使う。

## mut はブロックスコープ

vibe は純粋がデフォルト。ローカルな可変状態は `let mut` で、ブロックの外へは
値として出す。

```vibe
let y = {
  let mut v = 0
  v += 1
  v + 1
}
// y == 2
```

## 関数

トップレベルは `fn` 構文糖 (完全注釈必須、再帰に `rec` 不要)。let 形式・
ジェネリクス・ラベル付き引数も同じ意味論。

```vibe
fn add(x: Int, y: Int) -> Int { x + y }

fn fact(n: Int) -> Int {
  if n < 2 { 1 } else { n * fact(n - 1) }
}

fn identity[T](x: T) -> T { x }                       // ジェネリクス

let inc: (Int) -> Int = (x) -> { x + 1 }              // let 形式

let scaled: (x~: Int, y~: Int) -> Int = (x~, y~) -> { x * 10 + y }
scaled(x=4, y=2)                                      // ラベル付き呼び出し
```

## ラムダ短縮形とプレースホルダ

```vibe
Array::map(xs, _ * 2)        // (v) -> v * 2 の section
Array::fold(xs, 0, _ + _)    // (acc, v) -> acc + v
```

次章: [02 制御フロー](02_control_flow.md)

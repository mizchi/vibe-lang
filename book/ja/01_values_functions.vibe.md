# 01 — 値と関数

このチャプターは `.vibe.md` そのもの — 各 ` ```vibe run ` ブロックは
`pkf run vibe-md-tutorial` (`bash scripts/vibe_md.sh check book/src/*.vibe.md book/ja/*.vibe.md`)
で実際にコンパイル・実行され、直後の ` ```output ` ブロックは実行結果を
そのまま埋め込んだもの (#1142)。手元で更新するときは
`bash scripts/vibe_md.sh write book/ja/01_values_functions.vibe.md`。

English version: [01_values_functions.vibe.md](01_values_functions.vibe.md) (canonical)

## 値と基本型

束縛は `let`。型注釈は省略できる (推論される)。

`println` は builtin なので import は不要。ただし出力する関数には
`Stdout` row が必要になる — [Capabilities](../src/10_capabilities.vibe.md) 参照。

```vibe run
fn main with Console {
  let x: Int = 42
  // 63-bit tagged (#1877)。リテラル上限 2^62-1
  let d: Double = 3.14
  // 64-bit float (小数点リテラルの既定)
  let b: Bool = true
  let s = "answer \{x}"
  // 文字列補間は \{expr}
  let c = 'A'
  // char リテラルは文字コード (Int)。'A' == 65
  println("x = \{x}")
  println("d = \{d}, to_string = \{Double::to_string(d)}")
  // Double も \{expr} 補間 / Double::to_string で出せる
  println("d*100 as int = \{Double::to_int(d * 100.0)}")
  // 整数に丸めたいときは Double::to_int
  println("b = \{b}")
  println("s = \{s}")
  println("c = \{c}")
}
```

```output
x = 42
d = 3.14, to_string = 3.14
d*100 as int = 314
b = true
s = answer 42
c = 65
```

注意: 文字列の添字 `s[i]` は **文字コード (Int)** を返す。1 文字の String が
欲しいときは `String::from_char_code(s[i])` か slice を使う。

## mut はブロックスコープ

vibe は純粋がデフォルト。ローカルな可変状態は `let mut` で、ブロックの外へは
値として出す。

```vibe run
fn main with Console {
  let y = {
    let mut v = 0
    v += 1
    v + 1
  }
  println("y = \{y}")
}
```

```output
y = 2
```

## 関数

`fn` は予約語 ([#1280](https://github.com/mizchi/vibe-lang/issues/1280) で着地済み)。
関数宣言の綴りは `fn` で、binding・引数の名前には使えない。`r#fn` のような
raw identifier も escape hatch にはならない (実測: `let fn = 1` は
`expected identifier after 'let'`、`fn f(fn: Int)` は `expected parameter name`、
`let r#fn = 1` も同様に拒否)。既存の名前が衝突したら `fn_` などへ rename する。

```vibe skip
// skip: 予約語 `fn` の拒否例 (どれも parse error になることを示す断片)
let fn = 1
// error: expected identifier after 'let'
let r#fn = 1
// error: raw identifier は escape hatch にしない
```

宣言形式は以下がすべて runnable。トップレベル関数は完全注釈必須、再帰に
`rec` は不要。let 形式・ジェネリクス・ラベル付き引数も同じ意味論。

```vibe run
fn add(x: Int, y: Int) -> Int {
  x + y
}

fn fact(n: Int) -> Int {
  if n < 2 {
    1
  } else {
    n * fact(n - 1)
  }
}

fn identity[T](x: T) -> T {
  x
}
// ジェネリクス

let inc: (Int) -> Int = (x) -> {
  x + 1
}
// let 形式

let scaled: (x~: Int, y~: Int) -> Int = (x~, y~) -> {
  x * 10 + y
}

fn main with Console {
  println("add(1, 2) = \{add(1, 2)}")
  println("fact(5) = \{fact(5)}")
  println("identity(7) = \{identity(7)}")
  println("inc(41) = \{inc(41)}")
  println("scaled(x=4, y=2) = \{scaled(x=4, y=2)}")
  // ラベル付き呼び出し
}
```

```output
add(1, 2) = 3
fact(5) = 120
identity(7) = 7
inc(41) = 42
scaled(x=4, y=2) = 42
```

## 省略引数

末尾の `name?: T` は省略できる。呼び出し側は素の `T` を書くか省略する。
本体が見るのは `Option[T]`。

```vibe run
fn greet(name: String, times?: Int) -> String {
  let n = match times {
    Some(v) => v,
    None => 1
  }
  String::concat(name, String::concat(" x", __to_string(n)))
}

fn main with Console {
  println(greet("hi"))
  println(greet("hi", 3))
}
```

```output
hi x1
hi x3
```

## ラムダ短縮形とプレースホルダ

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  let doubled = Array::map(xs, _ * 2)
  // (v) -> v * 2 の section
  let total = Array::fold(xs, 0, _ + _)
  // (acc, v) -> acc + v
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("fold sum = \{total}")
}
```

```output
doubled = [2, 4, 6]
fold sum = 6
```

次章: [02 制御フロー](02_control_flow.vibe.md)

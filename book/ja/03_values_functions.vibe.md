# 03 — 値と関数

前: [小さなプログラム](02_a_small_program.vibe.md)

English version: [03_values_functions.vibe.md](../en/03_values_functions.vibe.md)

ツアーはここから始まります。この章は `let`、プリミティブ型、そして関数の
書き方すべてです。

## 値を束縛する

`let` は名前を束縛します。型注釈は省略可能（推論されます）で、束縛は
一度作られたら変わりません。

```vibe run
fn main with Console {
  let x = 42
  let name = "vibe"
  let ratio = 0.5
  let ready = true
  println("\{name} \{x} \{ratio} \{ready}")
}
```

```output
vibe 42 0.5 true
```

プリミティブは `Int` / `Double` / `Bool` / `String` / `Char` です。
明記したいとき、あるいは推論に手がかりがないときは注釈を書きます:

```vibe run
fn main with Console {
  let x: Int = 42
  let d: Double = 3.14
  let b: Bool = true
  let c = 'A'
  println("x = \{x}")
  println("d = \{d}, rounded = \{Double::to_int(d * 100.0)}")
  println("b = \{b}")
  println("c = \{c}")
}
```

```output
x = 42
d = 3.14, rounded = 314
b = true
c = 65
```

気づいてほしい点が2つ。文字列中の `\{...}` は補間で、任意の式が入ります。
そして `'A'` は `65` と印字されました — 文字リテラルはそのコードポイント
そのもの、つまり `Int` です。文字列の添字も数値を返しますが、`s[0]` は
そのオフセットの**バイト**であって、1文字の文字列ではありません。ASCII
ではコードポイントとバイトは同じ数値になり、その先は一致しません —
[型と文字列](05_types_strings.vibe.md)が扱います。1文字の `String` に
戻したいときは `String::from_char_code(s[0])` を使います。これはその
バイトをそのまま書き戻します。

正確な範囲と表現 — `Int` の幅が63ビットであることや `String` がバイト列で
あること — は[型と文字列](05_types_strings.vibe.md)にあります。それが
効いてくるまでには、かなりの量の vibe が書けます。

## ブロックの中のミューテーション

vibe は既定で不変です。アルゴリズムがカウンタを欲しがるときは `let mut` が
あり、それが住むブロックは値に評価されます:

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

可変な束縛はブロックの外に出ません。`y` はただの不変な `Int` です。
面白くなるのは[ミューテーション・region・エスケープ](06_mutation.vibe.md)
からです。

## 関数を書く

`fn` が関数を宣言します。トップレベルの関数は引数と戻り値に注釈を付け、
再帰にキーワードは要りません。

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

let inc: (Int) -> Int = (x) -> {
  x + 1
}

let scaled: (x~: Int, y~: Int) -> Int = (x~, y~) -> {
  x * 10 + y
}

fn main with Console {
  println("add(1, 2) = \{add(1, 2)}")
  println("fact(5) = \{fact(5)}")
  println("identity(7) = \{identity(7)}")
  println("inc(41) = \{inc(41)}")
  println("scaled(x=4, y=2) = \{scaled(x=4, y=2)}")
}
```

```output
add(1, 2) = 3
fact(5) = 120
identity(7) = 7
inc(41) = 42
scaled(x=4, y=2) = 42
```

このブロックには名前を付けておく価値のあるものが4つあります:

- **ジェネリクス。** `fn identity[T](x: T) -> T` は任意の `T` で動きます。
  境界は[ジェネリクス・trait・derive](15_generics.vibe.md)で足します。
- **`let` 形式。** 関数は値です。`let inc: (Int) -> Int = (x) -> { ... }` は
  同じ関数を束縛として書いたものです。
- **ラベル引数。** `x~: Int` と書くと呼び出し側は `x=4` と書け、順序も
  自由です。`Int` を3つ取る関数になったら欲しくなります。
- **本体は式。** `return` は要りません — 最後の式が結果です。

## 省略可能な引数

末尾の `name?: T` は呼び出し側が省略できます。本体には `Option[T]` として
届くので、既定値は match で述べます:

```vibe run
fn greet(name: String, times?: Int) -> String {
  let n = match times {
    Some(v) => v,
    None => 1
  }
  "\{name} x\{n}"
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

本体が見るのは `Option` なので、省略可能な `Bool` はそのままでは条件に
なりません。`flag?: Bool` に対する `if flag` は型エラーで、他の `Option` と
同様に match します。型そのものは
[Option とレールウェイ](10_option.vibe.md)で扱います。

## 小さいラムダの略記

`_` は引数の代わりに置けます。ラムダが演算子1つ分の幅なら読みやすくなります:

```vibe run
fn main with Console {
  let xs = [
    1,
    2,
    3
  ]
  let doubled = Array::map(xs, _ * 2)
  let total = Array::fold(xs, 0, _ + _)
  println("doubled = [\{Array::get(doubled, 0)}, \{Array::get(doubled, 1)}, \{Array::get(doubled, 2)}]")
  println("fold sum = \{total}")
}
```

```output
doubled = [2, 4, 6]
fold sum = 6
```

`_ * 2` は `(v) -> v * 2`、`_ + _` は `(acc, v) -> acc + v` です — `_` は
順に次の引数を取ります。

## コメント

`//` が行コメントを始めます。ブロックコメントの形式はないので、式のトークンの
間に挟みたいコメントは独立した行に置きます。宣言の直前の `///` はその宣言の
doc コメントで、hover や `vibe doc-at` が拾います。

## 使えない名前

キーワードは名前に使えませんが、多くは `r#` 接頭辞で回避できます —
`test` は test ブロックを開く語ですが `let r#test = 1` は通ります。
例外は `fn` で、これは回避できないので別の名前にしてください。
どちらの場合かは診断が教えてくれます。

次: [制御フロー](04_control_flow.vibe.md)。

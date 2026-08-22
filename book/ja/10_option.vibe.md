# 10 — Option とレールウェイ

前: [ケーパビリティ](09_capabilities.vibe.md)

English version: [10_option.vibe.md](../en/10_option.vibe.md)

そこに無いかもしれない値の型が `Option[T]` です — `Some(v)` か `None` の
どちらか。ただの enum で、コンパイラに組み込まれた特別なところは何もあり
ません。ただ、これに対してやりたいこと — **無かったら早めに止める** — が
あまりに頻出なので、言語が略記を3つ用意しています。

## 型そのもの

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with Console {
  let a = match half(10) {
    Some(v) => v,
    None => 0 - 1
  }
  let b = match half(3) {
    Some(v) => v,
    None => 0 - 1
  }
  println("half(10) = \{a}")
  println("half(3)  = \{b}")
}
```

```output
half(10) = 5
half(3)  = -1
```

`match` はいつでも使えて、いつでも正しく動きます。この章の残りは、これを
4回続けて書かないための話です。

## `?` — 取り出す、無ければ今すぐ `None` を返す

`Option[T]` の式の後ろに `?` を置くと `T` が得られます。`None` だったら、
囲んでいる関数がその場で `None` を返します:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let x = half(a)?
  let y = half(b)?
  Some(x + y)
}

fn main with Console {
  println("sum_halves(4, 6) = \{sum_halves(4, 6)}")
  println("sum_halves(4, 3) = \{sum_halves(4, 3)}")
}
```

```output
sum_halves(4, 6) = Some(5)
sum_halves(4, 3) = None
```

その関数自身も `Option` を返す必要があります。そこがこの取引の誠実な部分です
— `?` は「無い」を消すのではなく、呼び出し側に渡します。

## `let*` — 同じ考えをブロック全体に

`let* x = e` は `Some` の中身を束縛し、`None` のときはそれが置かれた
ブロックが `None` に評価されます:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let* x = half(a)
  let* y = half(b)
  Some(x + y)
}

fn main with Console {
  println("sum_halves(4, 6) = \{sum_halves(4, 6)}")
  println("sum_halves(4, 3) = \{sum_halves(4, 3)}")
}
```

```output
sum_halves(4, 6) = Some(5)
sum_halves(4, 3) = None
```

ここでは `?` と `let*` は同じ仕事をします。行の途中の1つの式には `?` が、
すべて成功しなければならない一連の手順には `let*` が向きます。

## `guard` — 束縛する、さもなくば抜ける

`None` を伝播させたくない場合もあります — その場で処理して、取り出した値で
続けたい。`guard` は**スコープの残り全体**に対して束縛し、その `else` は
必ず抜けなければなりません:

```vibe run
fn double_or_zero(o: Option[Int]) -> Int {
  guard o is Some(v) else {
    return 0
  }
  v * 2
}

fn main with Console {
  println("double_or_zero(Some(21)) = \{double_or_zero(Some(21))}")
  println("double_or_zero(None) = \{double_or_zero(None)}")
}
```

```output
double_or_zero(Some(21)) = 42
double_or_zero(None) = 0
```

最後の行で `v` がスコープにあり、しかもネストしていないことに注目して
ください — `match` ではなく `guard` を使う理由はそこにあります。

`else` は `return` か `throw(...)` で実際に関数を抜ける必要があります。
抜けなければならないのは、`guard` より後がすべて「`v` が存在する」前提で
書かれているからです。代替が抜け出しではなく**値**なら、
`if o is Some(v) { ... } else { ... }` を使ってください。

## 取り出さずに訊く

知りたいだけなら `is` が `Bool` を返します:

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with Console {
  println("half(10) is Some(_) = \{half(10) is Some(_)}")
  println("half(3) is None = \{half(3) is None}")
}
```

```output
half(10) is Some(_) = true
half(3) is None = true
```

## 「無い」が本題でないとき

`Option` は値が無いことを述べますが、**なぜ**無いのかは述べません。そして
理由こそが本題のこともあります — パースに失敗した、ファイルが壊れていた。
その場合、関数は `with Exception` を宣言してメッセージを投げます —
[エフェクト](08_effects.vibe.md) の章が最初に扱ったエフェクトです。
「そこに無い」が話の全部なら `Option` を、呼び出し側が理由を
知るべきなら `Exception` を選んでください。

次: [モジュールとパッケージ](11_modules_packages.vibe.md)。

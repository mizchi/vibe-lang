# 04 — Option

前章: [03 データ](03_data.vibe.md)

English version: [04_option.vibe.md](04_option.vibe.md) (canonical)

## Option

値がない可能性は `Option[T]` (`Some(v)` / `None`) で表す。

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn main with Console {
  println("half(10) unwrap_or -1 = \{unwrap_or(half(10), -1)}")
  println("half(3)  unwrap_or -1 = \{unwrap_or(half(3), -1)}")
}
```

```output
half(10) unwrap_or -1 = 5
half(3)  unwrap_or -1 = -1
```

## `let*` — 束縛して短絡

`let* x = e` は `Some(x)` を剥がして束縛し、`None` ならブロック全体を `None` で
短絡する。囲む関数全体は対応する `Option[...]` を返さなければならない。

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let* x = half(a)
  // None ならここで終わり
  let* y = half(b)
  Some(x + y)
}

fn main with Console {
  println("sum_halves(4, 6) unwrap_or -1 = \{unwrap_or(sum_halves(4, 6), -1)}")
  println("sum_halves(4, 3) unwrap_or -1 = \{unwrap_or(sum_halves(4, 3), -1)}")
}
```

```output
sum_halves(4, 6) unwrap_or -1 = 5
sum_halves(4, 3) unwrap_or -1 = -1
```

## `?` — 剥がすか早期 return

`e?` は `Some(v)` の中身を返し、`None` なら囲む関数から `None` を early-return
する。

```vibe run
fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn first_half(a: Int, b: Int) -> Option[Int] {
  let x = half(a)?
  let _unused = half(b)?
  Some(x)
}

fn main with Console {
  println("first_half(4, 6) unwrap_or -1 = \{unwrap_or(first_half(4, 6), -1)}")
  println("first_half(4, 3) unwrap_or -1 = \{unwrap_or(first_half(4, 3), -1)}")
}
```

```output
first_half(4, 6) unwrap_or -1 = 2
first_half(4, 3) unwrap_or -1 = -1
```

## `guard` — 束縛するか脱出

`guard e is PAT else { ... }` は `Some(v)` を剥がして `v` を**後続のスコープで**束縛し、
マッチしなければ `else` に入る。`match` のような右方向ネストなしで
「剥がして続行」を書ける。

`else` は**必ず脱出**する。`match e { PAT => <残り>, _ => else }` に脱糖されるので
`else` 腕は残りのブロックそのものの代わりに評価される位置にあり、脱出しないと
束縛されていない `v` を使う経路ができてしまうため。受理する脱出の形は
`return` と直接の `throw(...)` (実測: `guard o is Some(v) else { throw("no value") }`
は関数の row に `Exception` があればそのまま通り、呼び出し側の `handle` で
捕まえられる — [05 エフェクト](05_effects.vibe.md) 参照)。他の `perform` は
resume しうるので脱出とは数えない。

フォールバックが「脱出」ではなく「値」なら `if e is PAT { .. } else { .. }` を使う。

> 旧綴りの `let PAT = e else { ... }` (#760(1)) は廃止され、名指しの parse error に
> なる。同義ではない — 旧形の `else` はブロックの**残り全体**の値になったので、
> `let Some(v) = o else { 0 }` は残りの関数を黙って `0` に差し替えられた。
> `guard` が脱出を必須にしたのはこの形を消すため。

```vibe run
fn double_or_zero(o: Option[Int]) -> Int {
  guard o is Some(v) else {
    return 0
  }
  v * 2
  // v はここで使える
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

## クイックチェックは is 式

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
  // true
  println("half(3) is None = \{half(3) is None}")
  // true
}
```

```output
half(10) is Some(_) = true
half(3) is None = true
```

理由を伴う中断は次章の [Exception 境界](05_effects.vibe.md#exception-境界--perform--handle)
で扱う。

次章: [05 エフェクト](05_effects.vibe.md)

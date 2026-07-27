# 04 — Option と railway 演算子

前章: [03 データ](03_data.vibe.md)

## Option

失敗しうる計算は `Option[T]` (`Some(v)` / `None`) を返す。

```vibe run
import @vibe/prelude { stdout_write }

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 { Some(n / 2) } else { None }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

let _start: () -> Unit with { Stdout } = () -> {
  stdout_write("half(10) unwrap_or -1 = \{unwrap_or(half(10), -1)}\n")
  stdout_write("half(3)  unwrap_or -1 = \{unwrap_or(half(3), -1)}\n")
}
```

```output
half(10) unwrap_or -1 = 5
half(3)  unwrap_or -1 = -1
```

## `let*` — 束縛して短絡

`let* x = e` は `Some(x)` を剥がして束縛し、`None` ならブロック全体を `None` で
短絡する。囲む関数の戻り値は同じ `Option` 型であること。

```vibe run
import @vibe/prelude { stdout_write }

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 { Some(n / 2) } else { None }
}

fn unwrap_or(o: Option[Int], fallback: Int) -> Int {
  match o {
    Some(v) => v,
    None => fallback
  }
}

fn sum_halves(a: Int, b: Int) -> Option[Int] {
  let* x = half(a)      // None ならここで終わり
  let* y = half(b)
  Some(x + y)
}

let _start: () -> Unit with { Stdout } = () -> {
  stdout_write("sum_halves(4, 6) unwrap_or -1 = \{unwrap_or(sum_halves(4, 6), -1)}\n")
  stdout_write("sum_halves(4, 3) unwrap_or -1 = \{unwrap_or(sum_halves(4, 3), -1)}\n")
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
import @vibe/prelude { stdout_write }

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 { Some(n / 2) } else { None }
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

let _start: () -> Unit with { Stdout } = () -> {
  stdout_write("first_half(4, 6) unwrap_or -1 = \{unwrap_or(first_half(4, 6), -1)}\n")
  stdout_write("first_half(4, 3) unwrap_or -1 = \{unwrap_or(first_half(4, 3), -1)}\n")
}
```

```output
first_half(4, 6) unwrap_or -1 = 2
first_half(4, 3) unwrap_or -1 = -1
```

## `let-else` — 束縛するか脱出

`let PAT = e else { ... }` は `Some(v)` を剥がして `v` を**その先ずっと**束縛し、
マッチしなければ `else` に入る。`else` は脱出 (`return` / `throw`) する必要が
ある — `match e { PAT => <残り>, _ => else }` に脱糖され、両腕の型が合う必要が
あるため。`match` のような右方向ネストなしで「剥がして続行」を書ける。

```vibe run
import @vibe/prelude { stdout_write }

fn double_or_zero(o: Option[Int]) -> Int {
  let Some(v) = o else { return 0 }
  v * 2                              // v はここで使える
}

let _start: () -> Unit with { Stdout } = () -> {
  stdout_write("double_or_zero(Some(21)) = \{double_or_zero(Some(21))}\n")
  stdout_write("double_or_zero(None) = \{double_or_zero(None)}\n")
}
```

```output
double_or_zero(Some(21)) = 42
double_or_zero(None) = 0
```

## クイックチェックは is 式

```vibe run
import @vibe/prelude { stdout_write }

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 { Some(n / 2) } else { None }
}

let _start: () -> Unit with { Stdout } = () -> {
  stdout_write("half(10) is Some(_) = \{half(10) is Some(_)}\n")   // true
  stdout_write("half(3) is None = \{half(3) is None}\n")           // true
}
```

```output
half(10) is Some(_) = true
half(3) is None = true
```

## Result について

`let*` / `?` は組み込みの `Result` / `Option` を対象にするが、standalone
ファイルで気軽に使えるのは現状 Option (組み込み Result のコンストラクタ解決には
文脈依存の制限があり、コンビネータ群 `Result::and_then` などは workspace の
prelude 提供)。エラーに **理由** を持たせたいときの実用解は次章のエフェクト
(`throw` / `handle`) — vibe のエラーハンドリングの主役はそちら。

次章: [05 エフェクト](05_effects.vibe.md)

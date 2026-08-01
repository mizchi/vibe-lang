# 04 — Option

前章: [03 データ](03_data.vibe.md)

## Option

値がない可能性は `Option[T]` (`Some(v)` / `None`) で表す。

```vibe run
import @vibe/prelude {
  stdout_write
}

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

fn main with { Stdout } {
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
短絡する。囲む関数全体は対応する `Option[...]` を返さなければならない。

```vibe run
import @vibe/prelude {
  stdout_write
}

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

fn main with { Stdout } {
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
import @vibe/prelude {
  stdout_write
}

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

fn main with { Stdout } {
  stdout_write("first_half(4, 6) unwrap_or -1 = \{unwrap_or(first_half(4, 6), -1)}\n")
  stdout_write("first_half(4, 3) unwrap_or -1 = \{unwrap_or(first_half(4, 3), -1)}\n")
}
```

```output
first_half(4, 6) unwrap_or -1 = 2
first_half(4, 3) unwrap_or -1 = -1
```

## `let-else` — 束縛するか脱出

`let PAT = e else { ... }` は `Some(v)` を剥がして `v` を**後続のスコープで**束縛し、
マッチしなければ `else` に入る。現行では `else` は脱出 (`return` / `throw`) する必要が
ある — `match e { PAT => <残り>, _ => else }` に脱糖され、両腕の型が合う必要が
あるため。`return` を維持するかは [#1283](https://github.com/mizchi/vibe-lang/issues/1283) で
決める。`match` のような右方向ネストなしで「剥がして続行」を書ける。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn double_or_zero(o: Option[Int]) -> Int {
  let Some(v) = o else {
    return 0
  }
  v * 2
  // v はここで使える
}

fn main with { Stdout } {
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
import @vibe/prelude {
  stdout_write
}

fn half(n: Int) -> Option[Int] {
  if n % 2 == 0 {
    Some(n / 2)
  } else {
    None
  }
}

fn main with { Stdout } {
  stdout_write("half(10) is Some(_) = \{half(10) is Some(_)}\n")
  // true
  stdout_write("half(3) is None = \{half(3) is None}\n")
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

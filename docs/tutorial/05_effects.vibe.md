# 05 — エフェクト (vibe の核)

前章: [04 Option](04_option.vibe.md)

vibe は**純粋がデフォルト**。副作用は型の `with { ... }` 行 (effect row) で
宣言し、呼び出し側は `handle` で境界を引くまで伝播する。

## Exception 境界 — perform / handle

**目標の設計**では `Exception` は言語組み込みの、型引数を持たない**非再開
(abortive) エフェクト**である。`perform Exception::Throw(payload)` は継続を再開せず、
任意の `T: ToString` を payload にできる。handler arm で `resume` は使えず、その arm の
値が `handle` の結果になる。この構文は
[#1279](https://github.com/mizchi/vibe-lang/issues/1279) で追跡中であり、現在の
コンパイラでは実行しない。

```vibe skip
// target (#1279): Exception は unparameterized かつ abortive。
fn risky[T: ToString](x: Int, reason: T) -> Int with { Exception } {
  if x == 0 {
    perform Exception::Throw(reason)
  }
  100 / x
}

fn main with { Stdout } {
  let safe = handle {
    risky(0, 404)
  } with Exception {
    Throw(payload) => {
      stdout_write("exception: \{ToString::to_string(payload)}\n")
      -1
    }
  }
  stdout_write("safe = \{safe}\n")
}
```

## 現行互換: Error 境界

現在は `Error` と String payload の互換 API を使う。これは上の目標構文ではなく、
現在のコンパイラで検証される例である。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn risky(x: Int) -> Int with { Error } {
  if x == 0 {
    throw("division by zero")
  }
  100 / x
}

fn main with { Stdout } {
  // handle がエフェクトを捕まえて値に落とす
  let safe = handle {
    risky(0)
  } with Error {
    Throw(_msg) => -1
  }
  let fine = handle {
    risky(4)
  } with Error {
    Throw(_msg) => -1
  }
  stdout_write("safe = \{safe}\n")
  stdout_write("fine = \{fine}\n")
}
```

```output
safe = -1
fine = 25
```

## ユーザ定義エフェクト — perform / resume

エフェクトは「操作の宣言」。実装 (handler) は呼び出し側が与える。

```vibe run
import @vibe/prelude {
  stdout_write
}

effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with { Ask } {
  perform Ask::Value(q) + 1
}

fn main with { Stdout } {
  // handler が resume(v) で perform 地点に値を返す (one-shot tail-resumptive)
  let v = handle {
    answer_of("life")
  } with Ask {
    Value(_q) => resume(41)
  }
  stdout_write("v = \{v}\n")
}
```

```output
v = 42
```

ユーザー定義 effect は、実装を呼び出し側から差し替える必要がある場合の advanced な
手段である。これは resumptive かつ one-shot/tail-resumptive という制約を持つ。通常の
失敗は `Exception`（実装後）を使い、局所的な状態はまず `let mut` を検討する。判断基準は
[Effects vs let mut](../guide/when-to-use-effects.md) を参照。

## エフェクト多相

エフェクト行は変数にできる — 「渡された関数のエフェクトをそのまま持つ」
高階関数が書ける。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn apply_twice(f~: (Int) -> Int with { e }, x~: Int) -> Int with { e } {
  f(f(x))
}

fn main with { Stdout } {
  stdout_write("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}\n")
}
```

```output
apply_twice = 40
```

ホスト I/O (`Fs` / `Env` / `Http` など) も同じ仕組みの組み込みエフェクト。
handler は checker 用で、実行時は host import に直接 lower される。

次章: [06 テスト](06_tests.vibe.md)

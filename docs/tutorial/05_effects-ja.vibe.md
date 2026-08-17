# 05 — エフェクト (vibe の核)

前章: [04 Option](04_option-ja.vibe.md)

English version: [05_effects.vibe.md](05_effects.vibe.md) (canonical)

vibe は**純粋がデフォルト**。副作用は型の `with ...` 行 (effect row) で
宣言し、呼び出し側は `handle` で境界を引くまで伝播する。

## Exception 境界 — perform / handle

型引数なしの `Exception` は erased な **非再開 (abortive) エフェクト**で、
typed `Exception[E]` のどの kind とも互換である。`perform Exception::Throw` は継続を
再開せず、handler arm で `resume` は使えない。その arm の値が `handle` の結果になる。
erased な handler の payload は String/opaque 扱いで、handler をまたぐ型引数の保存は
しない。typed exception との使い分けは [ADR-0085](../exception-effect.md) を参照。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    perform Exception::Throw("division by zero")
  }
  100 / x
}

fn main with Stdout {
  let safe = handle {
    risky(0)
  } with Exception {
    Throw(message) => {
      stdout_write("exception: \{message}\n")
      0 - 1
    }
  }
  let fine = handle {
    risky(4)
  } with Exception {
    Throw(_) => 0 - 1
  }
  stdout_write("safe = \{safe}\n")
  stdout_write("fine = \{fine}\n")
}
```

```output
exception: division by zero
safe = -1
fine = 25
```

## 旧 `Error` 綴りからの移行

`Error` は effect row (`with Error`) とハンドラ名
(`handle { ... } with Error { ... }`) のどちらでも parse error になる。旧ソースは
`vibe fmt` で `Exception` へ書き換えられる。`throw("message")` は引き続き使える。

operation 修飾子の `perform Error::Throw(...)` だけは古い生成物を読む内部互換として
受理されるが、新しいソースでは `perform Exception::Throw(...)` を使う。

拒否される旧綴りの例 (実行例ではなく、移行説明のため `skip`):

```vibe skip
// Rejected source (kept in comments so `vibe fmt` does not rewrite the example):
// fn old_row() -> Int with Error { throw("old") }
// fn old_handler() -> Int {
//   handle { 1 } with Error { Throw(_) => 0 }
// }
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

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Stdout {
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
失敗は `Exception` を使い、局所的な状態はまず `let mut` を検討する。判断基準は
[Effects vs let mut](../guide/when-to-use-effects.md) を参照。

## `handle` が見えるもの

上の `handle { answer_of(...) }` が通るのは、`answer_of` が名前付き top-level
`fn` だから。`handle` が覆うすべての `perform` は静的に見えていなければなら
ない — 直接の `perform`、名前付き top-level `fn` の呼び出し、effect-row 注釈
付きのクロージャリテラル。

ローカル束縛を経由する呼び出しは perform を隠す。型検査は通ってもコンパイル
は拒否される — 直すのは型ではなく呼び出し側。

```vibe skip
// skip: ineligible handle — a local closure hides the perform from the handler
effect Ask {
  Once() -> Int
}

fn ask_once() -> Int with Ask {
  perform Ask::Once()
}

fn main() -> Int {
  let bump = (x: Int) -> Int { x + 1 }
  handle { bump(ask_once()) } with Ask {
    Once() => resume(41)
  }
}
// error (measured with `vibe check`): handle of effect 'Ask' cannot be compiled
// here. Every perform this handle covers has to be statically visible to it, so
// the handled body may only: perform directly, call a named top-level `fn`, or
// call a closure literal that carries an effect row annotation. A call through
// a local binding or a closure parameter hides the perform and is what this
// rejects (here: the call to 'bump') -- move the `handle` into the function
// that performs, or replace the indirect call with a direct one.
```

直し方は最後の文どおり: `handle` を perform する関数の中へ移すか、`bump(...)`
を直接呼び出し (または top-level `fn`) に置き換える。

## エフェクト多相

エフェクト行は変数にできる — 「渡された関数のエフェクトをそのまま持つ」
高階関数が書ける。

```vibe run
import @vibe/prelude {
  stdout_write
}

fn apply_twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main with Stdout {
  stdout_write("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}\n")
}
```

```output
apply_twice = 40
```

ホスト I/O (`Fs` / `Env` / `Http` など) も同じ仕組みの組み込みエフェクト。
handler は checker 用で、実行時は host import に直接 lower される。

次章: [06 テスト](06_tests-ja.vibe.md)

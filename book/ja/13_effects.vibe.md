# 05 — エフェクト (vibe の核)

前章: [04 Option](08_option.vibe.md)

English version: [13_effects.vibe.md](../en/13_effects.vibe.md) (canonical)

vibe は**純粋がデフォルト**。副作用は型の `with ...` 行 (effect row) で
宣言し、呼び出し側は `handle` で境界を引くまで伝播する。

## Exception 境界 — perform / handle

型引数なしの `Exception` は erased な **非再開 (abortive) エフェクト**で、
typed `Exception[E]` のどの kind とも互換である。`perform Exception::Throw` は継続を
再開せず、handler arm で `resume` は使えない。その arm の値が `handle` の結果になる。
erased な handler の payload は String/opaque 扱いで、handler をまたぐ型引数の保存は
しない。typed exception との使い分けは [ADR-0085](../../docs/exception-effect.md) を参照。

```vibe run
fn risky(x: Int) -> Int with Exception {
  if x == 0 {
    perform Exception::Throw("division by zero")
  }
  100 / x
}

fn main with Console {
  let safe = handle {
    risky(0)
  } with Exception {
    Throw(message) => {
      println("exception: \{message}")
      0 - 1
    }
  }
  let fine = handle {
    risky(4)
  } with Exception {
    Throw(_) => 0 - 1
  }
  println("safe = \{safe}")
  println("fine = \{fine}")
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
effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with Ask {
  perform Ask::Value(q) + 1
}

fn main with Console {
  // handler が resume(v) で perform 地点に値を返す (one-shot tail-resumptive)
  let v = handle {
    answer_of("life")
  } with Ask {
    Value(_q) => resume(41)
  }
  println("v = \{v}")
}
```

```output
v = 42
```

ユーザー定義 effect は、実装を呼び出し側から差し替える必要がある場合の advanced な
手段である。これは resumptive かつ one-shot/tail-resumptive という制約を持つ。通常の
失敗は `Exception` を使い、局所的な状態はまず `let mut` を検討する。判断基準は
[Effects vs let mut](../../docs/guide/when-to-use-effects.md) を参照。

## `handle` が見えるもの

上の `handle { answer_of(...) }` が通るのは、`answer_of` が名前付き top-level
`fn` だから。`handle` が覆うすべての `perform` はその `handle` から見えて
いなければならない — つまり handled body の呼び出し 1 つ 1 つについて、
コンパイラが「その呼び出しが何を perform するか」を判定できる必要がある。

ほとんどの呼び出しは見える — top-level `fn`、`println` のような builtin、
束縛や引数の型が effect row を持つクロージャ、そして handled body の中で
書かれたクロージャ。見えないのは、**外側のスコープから名前だけで届く row 無し
のクロージャ**で、定義も row も参照できない。この形は型検査を通ってもコンパイル
は拒否される — 直すのは型ではなく呼び出し側。

```vibe skip
// skip: ineligible handle — a rowless closure bound outside the handled body
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
// here: this handle cannot see what one call in its body performs (here: the
// call to 'bump'). Make that call visible -- declare 'bump' as a top-level
// `fn`, give the binding or parameter it arrives through an effect row (`with
// Ask`), or move its `let` inside the handled body. Moving the `handle` into
// the function that performs works too.
```

メッセージが挙げる 4 つの直し方のどれでも直る。ここで一番小さいのは `bump` を
top-level `fn` に出すこと。`let bump: (Int) -> Int with Ask = ...` と注釈する、
あるいは `let` を `handle` の中へ移すのも同じく有効。

## エフェクト多相

エフェクト行は変数にできる — 「渡された関数のエフェクトをそのまま持つ」
高階関数が書ける。

```vibe run
fn apply_twice(f~: (Int) -> Int with e, x~: Int) -> Int with e {
  f(f(x))
}

fn main with Console {
  println("apply_twice = \{apply_twice(f=(n) -> n * 2, x=10)}")
}
```

```output
apply_twice = 40
```

ホスト I/O (`Fs` / `Env` / `Http` / **`Console`**) は capability で、
代数 effect ではない。tty の現行名は `Console`（`Console::write_stream` /
`read_stream` / `write_err_stream` と `*_char`）。上の例の `Stdout` は
まだ受理される **legacy ラベル**で、同じ host import を共有する。
`Console` を宣言すれば legacy ラベルも認可されるが、逆は成立しない
（`Console` の方が広い capability のため）。詳細は英語版
[Capabilities](../en/14_capabilities.vibe.md)。

次章: [06 テスト](10_tests.vibe.md)

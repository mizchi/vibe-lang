# 05 — エフェクト (vibe の核)

実行: `vibe test docs/tutorial/05_effects_test.vibe`

vibe は**純粋がデフォルト**。副作用は型の `with { ... }` 行 (effect row) で
宣言し、呼び出し側は `handle` で境界を引くまで伝播する。

## Error 境界 — throw / handle

```vibe
fn risky(x: Int) -> Int with { Error } {
  if x == 0 { throw("division by zero") }
  100 / x
}

// handle がエフェクトを捕まえて値に落とす
let safe = handle { risky(0) } with Error { Throw(_msg) => -1 }   // -1
let fine = handle { risky(4) } with Error { Throw(_msg) => -1 }   // 25
```

エフェクト行を書かずに `throw` を呼ぶとコンパイルエラー — 「この関数は失敗
しうる」が型で強制されるのが railway (`Option`) との違い。

## ユーザ定義エフェクト — perform / resume

エフェクトは「操作の宣言」。実装 (handler) は呼び出し側が与える。

```vibe
effect Ask {
  Value(String) -> Int
}

fn answer_of(q: String) -> Int with { Ask } {
  perform Ask::Value(q) + 1
}

// handler が resume(v) で perform 地点に値を返す (one-shot tail-resumptive)
let v = handle { answer_of("life") } with Ask {
  Value(_q) => resume(41)
}
// v == 42
```

依存注入・モック・状態・ロガー — 「実装を外から差し替えたいもの」は全部
この形で書ける。テストでは handler を差し替えるだけでよい。

## エフェクト多相

エフェクト行は変数にできる — 「渡された関数のエフェクトをそのまま持つ」
高階関数が書ける。

```vibe
fn apply_twice(f~: (Int) -> Int with { e }, x~: Int) -> Int with { e } {
  f(f(x))
}
```

ホスト I/O (`Fs` / `Env` / `Http` など) も同じ仕組みの組み込みエフェクト。
handler は checker 用で、実行時は host import に直接 lower される。

次章: [06 テスト](06_tests.md)

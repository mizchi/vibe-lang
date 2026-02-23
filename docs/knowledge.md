# Knowledge Base

実装中に得られた設計知見・落とし穴をまとめる。

---

## K-001: Pure cache と effect 関数の相互作用

- 場所: `src/checker/purity.mbt`, `src/runtime/eval.mbt`
- 発見: 2026-02

### 背景

vibe ランタイムは pure 関数の結果を content-addressed cache に保存する（`eval_user_call` の `pure_cache`）。同じ引数で呼ばれた pure 関数は cache から即座に返される。

### 問題

`purity_for_let` が関数の `effects` 宣言を無視していた (`effects=_`)。これにより `with { Fs }` のような effect 付き関数でも、body が pure なら関数全体が pure と判定された。

```vibe
export let exists = (path: String) -> Bool with { Fs } {
  do { fs_exists(path) }
}
```

この関数は `fn_val.pure = true` になり、同じ `path` で2回呼ぶと2回目は cache から stale な結果が返った。

```vibe
let before = do { exists(path) }  // true (実行)
do { rm(path) }                   // ファイル削除
let after = do { exists(path) }   // true (cache!) ← 本来 false
```

### 修正

`purity_for_let` で `fn_effects.length() > 0` なら body 分析に関わらず impure とする。

### 教訓

- **pure cache は正確な purity 判定に依存する**。purity 判定ロジックを変更する場合は、effect 付き関数のテスト（特に同じ引数での複数回呼び出し）で cache 挙動を検証すること。
- purity 判定に影響する要素: `let mut`, `do {}`, **effect 宣言**, 外部関数呼び出し。

---

## K-002: `do {}` ブロックの purity の二面性

- 場所: `src/checker/purity.mbt`
- 発見: 2026-02

### 背景

vibe には2つの独立した purity 系統がある:

1. **Effect guard** (`require_effect_guard`): builder 操作に `do {}` を要求する仕組み
2. **Purity analysis** (`check_toplevel_purity`): トップレベル束縛を Pure / StateLocal / Impure に分類する仕組み

### 問題

`Do` ブロックは effect guard のために存在するが、purity analysis では当初 `impure` として扱われていた。これにより `do {}` 内で builder を使う関数が StateLocal/Impure に分類され、不要な診断ノイズが発生していた。

### 修正

`Do` ブロック自体は purity analysis では `pure` とする（impurity を encapsulate する境界として扱う）。ただし K-001 の通り、effect 宣言がある関数は別途 impure にする。

### 教訓

- `do {}` は「ここに副作用がある」というマーカーだが、purity 判定においては「副作用が外部に漏れない」という encapsulation の意味を持つ。
- effect guard と purity analysis は独立した系統。片方の変更がもう片方に波及しないか確認すること。

---

## K-003: インタプリタの loop fuel

- 場所: `src/runtime/eval.mbt`, `src/runtime/store.mbt`
- 発見: 2026-02

### 背景

`eval_while_expr` と `eval_loop_expr` に反復上限がなく、`while true {}` で CPU 300% (3スレッド: メイン + MoonBit GC) の暴走が発生。

### 設計

- デフォルト fuel: **100,000** 反復
- 環境変数 `VIBE_LOOP_FUEL` で上書き可能
- fuel 消費は while/loop の body 実行ごとに 1 減算
- fuel 切れで `EvalError::LoopFuelExhausted` を raise

### 実測値

| fuel | 消費時間の目安 |
|------|--------------|
| 100K | 数秒以内 |
| 1M | 30秒前後 |
| 10M | 数分 |

インタプリタの1反復あたりオーバーヘッドが大きいため、重い計算は WASM コンパイル実行を使う方針。

### 教訓

- インタプリタは簡易テスト・REPL 向け。ベンチマーク等は `BenchBackend::Wasm` がデフォルト。
- `fork_for_test` でも fuel をリセットする（テストごとに独立した fuel 予算）。

---

## K-004: Cascading diagnostics (依存モジュールの型エラー伝播)

- 場所: `src/runtime/db_query.mbt`, `src/cmd/vibe/cli.mbt`
- 発見: 2026-02

### 問題

依存モジュールに型エラーがある場合、`type_check_with_env` が catch して空の `TypeEnv` を返す。すると export された名前が importerの型環境に入らず、「unknown function」という misleading なエラーが表示される。

### 修正

import 解決時に `exported_names` (AST レベル) と `imported_env` (型レベル) の不一致を検出し、根本原因を示す diagnostic を emit する。CLI では依存側の diagnostic を先に表示する (root cause priority)。

### 教訓

- **AST レベルの export list** と **型レベルの名前解決** は別物。両者の不一致が cascading error の兆候。
- エラー表示は root cause を先に出す。ユーザーにとって「依存先を直して」が最も有用な情報。

---

## K-005: codebase テストの環境依存

- 場所: `src/codebase/codebase_test.mbt`
- 発見: 2026-02

### 問題

`index.lock` がリポジトリルートに存在すると、codebase の lock root 解決テストがルートの `index.lock` を見つけてしまい、テスト用の `.tmp/` ディレクトリ内の lock ファイルが使われない。

### 影響

10件の codebase テストが環境依存で失敗する。コンパイラ・ランタイムの変更とは無関係。

### 備考

`index.lock` は git status で untracked/modified として表示されるが、テスト実行に影響する。CI では `index.lock` が存在しないため問題にならない。

# Effect Prototype Plan

## Goal

0.1.0 の release blocker から切り離した状態で、cross-call `perform` / `resume` の実装コストと設計制約を見積もる。
ここで答えたいのは、WASM の linear backend において関数呼び出しを跨ぐ effect handler をどこまで載せられるか、そしてその実装面積が selfhost まで含めて現実的かどうかである。

この prototype は `assert_eq` 系の作業とは独立に進める。

## Minimal Scope

最初の prototype は次に限定する。

- linear/WASM backend を優先
- effect は 1 〜 2 系統で十分
- direct call / nested user call / nested handle-resume を確認できればよい
- `throw` / `suberror` / `Net` / `vibe serve` は対象外
- GC backend は同時完成を狙わない

## Selected Canonical Cases

### 1. `vibe integration handle catches error`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- 最小の `handle { ... } { ... }` と `perform` / `resume` の往復を確認できる
- `Error` effect は既存の標準パスなので、prototype の baseline にしやすい

What it verifies:
- handler が `perform` を捕捉できる
- `resume` で値を返せる
- 単発 effect の round-trip が壊れていない

### 2. `vibe integration perform handle typed payload`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- typed payload を持つ effect op を扱える
- `resume` による payload 返却の型整合を見られる

What it verifies:
- effect op の引数が型付きで通る
- `resume` した値が caller 側で正しく使われる

### 3. `vibe integration perform multi-layer handle`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- handler の入れ子と pass-through を見られる
- prototype で一番壊れやすい「外側 handler に effect を流す」経路を含む

What it verifies:
- nested handler の dispatch 順序
- inner handler が処理しない effect を outer handler に返せる
- multi-layer effect scope が checker/codegen で一致する

### 4. `vibe integration resume continues after perform`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- `resume` の後に callee の残り評価が継続するかを確かめる
- cross-call effect の本質的な continuation semantics を確認できる

What it verifies:
- `resume` 後に `perform` 以降の式が続く
- caller/callee の評価順が壊れていない

### 5. `vibe integration resume multi-layer perform`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- multi-layer handler と `resume` を同時に使う
- prototype で見たい nested continuation の最小実戦例になる

What it verifies:
- inner handler の `resume` が outer context と衝突しない
- nested effect chain の再開が壊れない

### 6. `vibe integration resume rejects prior effects before perform`

File: [src/tests/vibe_integration_test.mbt](/Users/mz/ghq/github.com/mizchi/vibe-lang/src/tests/vibe_integration_test.mbt)

Why:
- continuation の不正な再利用・順序違反を明示的にチェックできる
- prototype の single-shot 制約確認に使える

What it verifies:
- `resume` の順序制約
- prior effects を先に処理するパスが拒否されること

### 7. `filter all pass` / `map double` / `swap behavior`

File: [vibe/x/collect/collect_effect_test.vibe](/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/x/collect/collect_effect_test.vibe)

Why:
- 複数回の `perform` と handler の繰り返しを見られる
- `Predicate` / `Transform` のような capability 分離を確認できる

What it verifies:
- 1 回の handler で複数 `perform` を扱える
- 値変換型の effect が連続して動く
- handler の分岐で behavior を差し替えられる

### 8. `process mock exec` / `tcp mock connect + write + read`

Files:
- [vibe/process/process_effect_test.vibe](/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/process/process_effect_test.vibe)
- [vibe/socket/socket_effect_test.vibe](/Users/mz/ghq/github.com/mizchi/vibe-lang/vibe/socket/socket_effect_test.vibe)

Why:
- capability 系 effect の実用例になる
- I/O 系の複数 op を順に捌くため、prototype の現実度が見える

What it verifies:
- typed op を複数持つ effect が動く
- `handle` で mock implementation を注入できる
- effect を使った capability 分離の最小ケースになる

## Priority

prototype の着手順は次の順でよい。

1. `handle catches error`
2. `perform handle typed payload`
3. `perform multi-layer handle`
4. `resume continues after perform`
5. `resume multi-layer perform`
6. `resume rejects prior effects before perform`
7. `filter all pass` / `map double` / `swap behavior`
8. `process mock exec` / `tcp mock connect + write + read`

この順番の意図は、まず `resume` の最小 round-trip を確認し、その後に nested handler と capability 系を広げることにある。

## Technical Questions

prototype で見積もりたい論点は次の通り。

- handler は callee をまたいでどこで捕捉するか
- `resume` の値はどこに保持し、どう再開位置へ戻すか
- single-shot をどう守るか
- nested handler の pass-through を checker でどう表現するか
- effect op の typed payload を codegen でどう運ぶか
- import ベースの effect と user-defined effect をどう分離するか
- selfhost で再現するときに、どの subsystem が最初に壊れやすいか

## Prototype Success Criteria

以下が満たせたら、prototype は見積もり材料として十分である。

- caller 側 handler が callee 側 `perform` を捕捉できる
- `resume` 後に callee の残り評価が継続する
- nested handler で再送出 / passthrough の少なくとも一方が動く
- typed payload の `perform` が checker と codegen の両方で通る
- capability 系 effect で複数 op を順に捌ける
- wasm size, compile time, runtime overhead のラフ値を取れる
- selfhost 影響範囲を subsystem 単位で列挙できる

## Estimated Touched Subsystems

prototype の最小実装で触る可能性が高い subsystem は次の通り。

- `src/checker/typecheck_env.mbt`
- `src/checker/typecheck_call_builtin_handler_collection_numeric.mbt`
- `src/checker/typecheck_expr.mbt`
- `src/codegen/wasm_codegen_expr.mbt`
- `src/codegen/wasm_codegen_call.mbt`
- `src/codegen/wasm_codegen_call_builtin_pre_user.mbt`
- `src/codegen/wasm_codegen_sig.mbt`
- `src/codegen/wasm_codegen_expr_effect_wbtest.mbt`
- `src/runtime/eval.mbt`
- `src/tests/vibe_integration_test.mbt`
- `src/tests/vibe_wasm_eval_test.mbt`

## Expected Output

prototype の完了物はコードではなく、まず見積もり結果である。

- 方式候補の比較メモ
  - CPS
  - continuation stack
  - hybrid
- 触る subsystem の確定リスト
- 1 回の call chain あたりの実装面積
- selfhost まで含めた難所の見積もり
- `0.1.x` に入れるか `0.2` に送るかの判断材料

## Non Goals

prototype では次をやらない。

- `throw(x)` の完全統一
- `suberror` の全面移行
- `Net` capability の細分化
- WIT mapping の本実装
- `vibe serve` の追加
- GC backend の同時完成

## Next Implementation Order

1. `handle catches error` と `perform handle typed payload` を基準に最小 spike を切る
2. `perform multi-layer handle` と `resume continues after perform` を通して dispatch/resume の基本形を固める
3. `resume multi-layer perform` と `resume rejects prior effects before perform` で single-shot / nested continuation の制約を確認する
4. `src/checker/typecheck_env.mbt` と `src/codegen/wasm_codegen_expr.mbt` の影響範囲を確定する
5. `src/codegen/wasm_codegen_expr_effect_wbtest.mbt` に最小回帰を追加する
6. runtime / selfhost への波及範囲を見積もる
7. CPS / continuation stack / hybrid の比較メモを残す
8. 実装面積と compile/runtime overhead を計測し、`0.1.x` か `0.2` かを決める

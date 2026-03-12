# ADR-0013: Num 制約の単相化 (Monoify)

- Date: 2026-02-17
- Status: proposed (未着手)

## Context

`Int/Float/Double` の算術演算をジェネリクスで記述すると、ランタイムで boxing や動的ディスパッチが発生し、WASM の `i32/f32/f64` ネイティブ命令を直接利用できない。数値プリミティブに限定した単相化（monomorphization）により、分岐・boxing なしで効率的なコードを生成したい。

## Decision

`Num` 制約付きジェネリクスを対象に、コンパイル時に具体型へ特殊化する monoify パスを導入する。

### スコープ

- 対象型: `Int`, `Float`, `Double`
- 対象演算: `+ - * / == <` (`__add/__sub/__mul/__div/__eq/__lt/__neg`)
- 対象関数: `T: Num` 制約を含む関数のみ

### 型システム

- 型変数に制約集合（`Num`）を持たせる
- `__add` 等の型推論時に引数が型変数なら `Num` 制約を自動付与
- 具体型への解決時に `Num` メンバーか検証（不整合は型エラー）

### Monoify パス

```
parse -> typecheck -> monoify -> codegen
```

1. 型付け後 AST を走査し、`T: Num` 関数呼び出しの具体型を収集
2. `MonoKey = (fn_id, [type_arg...])` ごとに関数定義を複製・型変数を具体型に置換
3. 呼び出しサイトを特殊化関数へ差し替え
4. codegen で `i32/f32/f64` 命令を直接 emit

### しないこと

- `&Num` のようなランタイム共通表現の導入
- 完全な trait システム（`Num` 限定で開始）
- 全ジェネリクスの monoify

## Consequences

- 数値演算で boxing・分岐が消え、wasm-gc/wasm-js-string 両ターゲットで性能向上
- `fn_id + type_args` による生成名で content-addressed モジュールとの整合性を維持
- 将来 `Num` 以外の trait に monoify を拡張する際の基盤となる
- 関数複製によるコードサイズ増加のトレードオフがある

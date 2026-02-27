# ADR-0001: Named 型の遅延展開（Lazy Enum Expansion）

## Status

Accepted (2026-02-27)

## Context

vibe-lang の型チェッカーは `normalize_type` 関数で Named 型を Variant 型に展開する。
例えば `Named("Expr", [])` は 30+ コンストラクタを持つ `Variant(Map[String, Type])` に展開される。

### 現状の問題

プロファイル（parser.vibe 18.1s）:
- `normalize_type_inner`: 27% — Named→Variant 展開の実行コスト
- `structural_hash`: 19% — 巨大な Variant のハッシュ計算
- `type_has_substitutable_var`: 10% — Variant 内の再帰走査

これらは全て「型が大きい」ことに起因する。Named("Expr", []) は数十バイトだが、
展開後の Variant は 30+ エントリの Map を含み、各ペイロードもさらにネストする。

### 根本原因

`normalize_type` のデフォルトが `expand_enum=true`。
約 35 箇所の呼び出しのうち、Variant 形式を**実際に必要とする**のは以下のみ:

1. **match 式の網羅性チェック** — Variant のコンストラクタ一覧が必要
2. **パターンマッチの型チェック** — Variant 構造を参照
3. **unify で異なる Named 名の比較** — 展開して構造比較が必要

残り 25+ 箇所は型の解決（TVar→具体型、型エイリアス展開）だけで十分。

### OCaml の設計からの学び

OCaml の型チェッカーは Named（`Tconstr`）を正規形として保持し、
enum 定義の展開は必要な時だけ遅延的に行う。
これにより型の比較・ハッシュが常に軽量に保たれる。

## Decision

**`normalize_type` のデフォルトを `expand_enum=false` に変更する。**

具体的には:

1. `normalize_type(env, ty)` → `expand_enum=false`（Named を保持）
2. 新規: `normalize_type_expand_enum(env, ty)` → `expand_enum=true`（Variant に展開）
3. 既存: `normalize_type_preserve_enum(env, ty)` → 削除（`normalize_type` と同一になるため）
4. Variant 展開が必要な箇所のみ `normalize_type_expand_enum` を使用

### 展開が必要な箇所（変更先: `normalize_type_expand_enum`）

| ファイル | 行 | 用途 |
|---------|-----|------|
| typecheck_expr.mbt | ~728 | match 式の scrutinee 型（網羅性チェック） |
| typecheck_pattern.mbt | ~17 | パターンの型正規化 |
| typecheck_unify.mbt | ~1152-1166 | 異なる Named 名の unify フォールバック |

### 展開不要な箇所（`normalize_type` のまま）

- 関数パラメータ・戻り値の型解決
- 配列要素・Map 値の型解決
- let 束縛の型解決
- ハンドラの resume 型解決
- 組み込み関数の型解決
- generalize 時の型解決

## Consequences

### Positive

- **normalize_type_inner の実行回数が大幅に減少**: 大部分の呼び出しで enum 展開をスキップ
- **型サイズの縮小**: Named("Expr", []) のまま保持 → 比較・ハッシュが O(name長) に
- **キャッシュ効率の向上**: 小さい型はキャッシュヒット率が高い
- **将来のインターニングへの布石**: Named 型は小さく一意なので intern に適する

### Negative

- **呼び出し箇所の分類が必要**: 各 call site が Variant を必要とするか判断が必要
- **見落としリスク**: 展開が必要な箇所で `normalize_type` を使うとバグになる
  - 対策: 既存テスト（765件）で検出、match 式のテストが特に重要

### Risks

- unify 内の Named 同士の比較で、名前は同じだが引数が異なるケースの処理
  - 対策: Named 同士は名前比較 + 引数の再帰 unify で処理（既存ロジック）
- struct 定義の展開（Named→Record）も同様に遅延化すべきか
  - 対策: 今回は enum のみ。struct は別途検討

## Implementation Plan

### Step 1: 関数リネーム

- `normalize_type` を `expand_enum=false` に変更
- `normalize_type_expand_enum` を新設（旧 `normalize_type` の動作）
- `normalize_type_preserve_enum` を削除

### Step 2: 展開必須箇所の更新

- match 式 scrutinee → `normalize_type_expand_enum`
- パターンマッチ → `normalize_type_expand_enum`
- unify フォールバック → `normalize_type_expand_enum`

### Step 3: テスト・ベンチマーク

- `moon test`（765件）が全て通ること
- parser.vibe のチェック時間を計測（目標: 18.1s → 10s 以下）

## Results

変更箇所: 6 call sites を `normalize_type_expand_enum` に変更、残り 25+ は `normalize_type`（展開なし）のまま。

| ファイル | Before (CPU) | After (CPU) | 改善率 |
|----------|-------------|-------------|--------|
| printer.vibe | 1.74s | 0.29s | 6.0x |
| parser.vibe | 18.1s | 3.5s | 5.2x |

765 テスト全て通過。既存の動作に影響なし。

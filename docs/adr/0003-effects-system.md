# ADR-0003: エフェクトシステム

- Date: 2026-02-16
- Status: accepted
- Updated: 2026-02-24 (do 境界検証の廃止)
- Updated: 2026-03-18 (Model 1 Full Algebraic Effect 方針追加)

## Context

vibe は「pure by default」を目指しており、副作用を型レベルで追跡する仕組みが必要だった。単純なエフェクト宣言だけでは、意図しない副作用の混入を防ぎきれない。

## Decision

### 初期設計（v1）

二層のエフェクト検証を導入:

1. **エフェクトセット検証**: 関数の `with {Effect}` 宣言が、関数本体で使用するエフェクトを網羅しているか検査する
2. **do 境界検証**: 直接的な副作用ビルトイン（`sh`, `stdout_write` 等）やミュータブルビルダーは `do { }` ブロック内でのみ呼び出し可能

### 簡素化（v2, 2026-02-24）

`do` 境界検証を廃止し、エフェクトセット検証のみに一本化:

- `with { Effect }` 宣言のみでエフェクトを管理する
- `do { }` 構文は引き続きパース可能だが、チェッカーによる強制は行わない
- ビルダー操作（`ArrayBuilder::new` 等）は `do` なしで使用可能
- `for-in` は内部的に `do` ブロックにデシュガーされる（purity 境界として機能）

**廃止理由**:
- `with { Effect }` 宣言済みの関数で `do` は冗長（I/O ラッパーが全て `do { builtin() }` のパターン）
- `for-in` デシュガーや配列操作が内部でビルダーを使うため、ユーザーレベルでは既に隠蔽されている
- 二層あることで学習コストが高い

## 現在の実装状態

- エフェクトチェッカー (`checker_effects.vibe`) は `in_effect: Bool` の二値フラグで実装
- エフェクト名の個別追跡（エフェクトセット）は未実装
- `EFn` の第5フィールド `Option[String]` がエフェクト注釈を保持
- `EHandle` は `in_effect=true` にするだけで、エフェクト名の区別なし

## 発展方針

ADR-0021 でユーザー定義エフェクト（`effect Mut<T> { ... }`）と `perform`/`resume`
を導入し、本 ADR のエフェクトセット検証を拡張する計画:

- `in_effect: Bool` → `EffectSet = Array[String]` に拡張
- `handle ... with EffectName { ... }` でエフェクトを消去
- 既存の `handle { } { Error(_) => ... }` はそのまま維持（後方互換）

## Diagnostic Unification (2026-02-10)

`TypeError::EffectNotAllowed` を廃止し `TypeError::EffectGuardNotSatisfied` に統合。effect-set 不一致と do 境界不一致を同一の診断形式で報告する。

- `EffectGuardNotSatisfied` バリアント: `operation~`, `missing_effect~`, `missing_do_boundary~` フィールド
- 実装: `src/checker/typecheck_errors.mbt`
- テスト: `fixtures/typecheck/effect_guard_missing_*`, `fixtures/typecheck/generic_effect_missing_*`, `fixtures/typecheck/generic_effect_wrapper_*`

## Generics + Effects Test Matrix (2026-02-10)

ジェネリクスとエフェクトの組み合わせを網羅するフィクスチャマトリクス。

成功ケース:
- `generic_effect_matrix_ok_with_e_try_catch_localized`
- `generic_effect_matrix_ok_trait_and_effect_bound`
- `generic_effect_matrix_ok_passthrough_pure`

失敗ケース:
- `generic_effect_matrix_fail_missing_effect_at_caller`
- `generic_effect_matrix_fail_trait_and_effect_mixed`
- `generic_effect_matrix_fail_missing_wrapper_effect`

(すべて `fixtures/typecheck/` 以下、`.vibe` + `.diag` ペア)

## Consequences

- 純粋関数とエフェクトフル関数の区別が型シグネチャに表れ、コードの意図が明確になる
- `do {}` はランタイムで shared-mut セマンティクスを提供する（eval_block_shared_mut）ため、AST ノードとしては存続
- 将来の `{Async}`, `{Net}` 等のエフェクト追加が自然に拡張可能（ADR-0012 参照、延期中）
- ユーザー定義エフェクトと Component Model 統合は ADR-0021 で計画

## 発展方針: Model 1 Full Algebraic Effect (2026-03-18)

WASI P3 HTTP サポートを契機に、エフェクトシステムの発展方針を決定:

**設計決定**: Request/Response を含むすべての外部 capability を effect として扱う (Model 1)。
データ受け渡しではなく capability ベース。最小権限・テスト容易性・streaming を重視。

```
effect HttpRequest {    // incoming request の読み取り capability
  Method -> String;
  Url -> String;
  Header(String) -> Option[String];
  Body -> String
}

effect HttpResponse {   // response の書き込み capability
  Status(Int) -> Unit;
  Header(String, String) -> Unit;
  Write(String) -> Unit
}
```

実装ロードマップ:
1. WASM Exceptions の string throw/catch 修正
2. `effect` 宣言 / `perform` / `resume` / effect handler の言語サポート
3. Http effect 定義 + P3 adapter 統合
4. ADR-0027 capability-based DCE との連携

詳細: ADR-0021 の「WASI P3 HTTP の具体例」セクション、`docs/report/support-wasip3.md`

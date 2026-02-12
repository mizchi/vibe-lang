# Generics + Effects Fixture Matrix

Status: accepted (2026-02-10)
Source: TODO.md "P0 [done 2026-02-10]: Add a generics+effects fixture matrix (success/failure pairs)"

## 概要

ジェネリクスとエフェクトの組み合わせを網羅するフィクスチャマトリクスを追加した。`with {e}` による高階ラッパー、局所化された `try/catch`、trait/effect 混合の成功・失敗ペアをカバーする。

## 決定事項

- 成功ケース: `with {e}` エフェクト伝搬、`try/catch` 局所化、trait + effect bound の同時使用
- 失敗ケース: 呼び出し元のエフェクト宣言不足、ラッパーのエフェクト宣言不足、trait/effect 混合不整合
- 各ケースに `.vibe` ソースと `.diag` 期待値のペアを配置

## 背景・理由

ジェネリクスとエフェクトの相互作用は型チェッカーの複雑な領域であり、回帰テストの網羅性が不足していた。成功/失敗のマトリクスを明示的に配置することで、診断メッセージの正確性とエフェクト伝搬ロジックの健全性を継続的に検証できるようにした。

## 実装

- `fixtures/typecheck/` ディレクトリ以下のマトリクスフィクスチャ群

## テスト

成功ケース:
- `fixtures/typecheck/generic_effect_matrix_ok_with_e_try_catch_localized.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_matrix_ok_trait_and_effect_bound.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_matrix_ok_passthrough_pure.vibe` / `.diag`

失敗ケース:
- `fixtures/typecheck/generic_effect_matrix_fail_missing_effect_at_caller.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_matrix_fail_trait_and_effect_mixed.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_matrix_fail_missing_wrapper_effect.vibe` / `.diag`

# Effect Diagnostics Unification

Status: accepted (2026-02-10)
Source: TODO.md "P0 [done 2026-02-10]: Unify effect diagnostics for effect-set vs do boundary failures"

## 概要

`TypeError::EffectNotAllowed` を `TypeError::EffectGuardNotSatisfied` に統合し、effect-set 不一致と do 境界不一致を同一の診断形式で報告するようにした。

## 決定事項

- `TypeError::EffectNotAllowed` を廃止し、`TypeError::EffectGuardNotSatisfied` に統合
- 統合後の診断は hint/note 形式で、不足しているエフェクト宣言と不足している do 境界の両方を報告
- effect-set 失敗と do-boundary 失敗が同じグループ化された診断形状を共有

## 背景・理由

エフェクト関連のエラーが二系統に分かれていたため、ユーザーにとって診断メッセージの理解が困難だった。統合により、エフェクト不足の原因（宣言漏れ or 境界漏れ）を一つの診断で明示的に提示できるようになった。

## 実装

- `src/checker/typecheck_errors.mbt` - `EffectGuardNotSatisfied` バリアント（`operation~`, `missing_effect~`, `missing_do_boundary~` フィールド）

## テスト

- `fixtures/typecheck/effect_guard_missing_effect_and_do_boundary.vibe` / `.diag`
- `fixtures/typecheck/effect_guard_missing_do_boundary_only.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_missing_caller_effect.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_wrapper_requires_effect_decl.vibe` / `.diag`
- `fixtures/typecheck/generic_effect_concrete_effect_mismatch.vibe` / `.diag`

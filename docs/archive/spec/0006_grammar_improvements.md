# Grammar / Language Cleanup (2026-02-09)

Status: accepted (2026-02-09)
Source: TODO.md "Grammar/language cleanup candidates (from std refactor & test split)" 各 [done 2026-02-09] 項目

## 概要

std リファクタリングとテスト分割から発見された文法・言語上の改善点を一括で実施した。import リスト末尾カンマ、ローカル let 型注釈、非引用テスト名、loop 式、負リテラル境界 UX、import パース診断の改善を含む。

## 決定事項

1. **Import リスト末尾カンマ**: `import { a, b, } from "./m.vibe"` を許容。parser が named import リスト内の trailing comma + trivia/newlines を受理
2. **ローカル let 型注釈**: `let x: T = expr` 形式を parser が受理。型不一致時の診断もカバー
3. **非引用テスト名**: `test smoke_case { ... }` を受理（引用形式も引き続きサポート）
4. **コンテキスト依存キーワード**: `map` と `loop` をコンテキスト依存キーワード化。`map { ... }` はマップリテラル (`map_kw`)、`let map = ...` / `map(...)` は識別子 (`name`)。`loop { ... }` は `while true` へのデシュガー。lexer が次トークンを見て判定
5. **負リテラル境界 UX**: `Int` 最小値 (`-2147483648`) に対して `IntMinLiteralBoundary` 専用診断とリライトヒントを出力
6. **Import パース診断**: `from` キーワード欠落、リストセパレータ不正、余分なカンマを区別する診断ヒントを追加
7. **Formatter 安定性**: `trait Eq` / `impl Eq for Int` のスペーシング、引用 `test "name"`、文字列/文字リテラル引用符保持、import join スペーシングの parse-stability バグを修正
8. **Formatter 回帰テスト**: `import`, `trait/impl`, `test`, エフェクトシグネチャ (`with {..}`), 文字列アサーションの round-trip fixture を追加
9. **mutable enum payload**: `mut` に対して dedicated parse diagnostic を出力
10. **Cross-module trait import**: transitive cross-module trait import/export のフィクスチャ回帰カバレッジ追加
11. **Polymorphic recursion**: 専用の型診断 (`polymorphic_recursion_unsupported` fixture) を出力

## 背景・理由

std ポートおよびテスト分割の過程で、パーサーやフォーマッタの粗さが多数発見された。ユーザーが直面する構文上の摩擦点を一括して改善し、エラーメッセージの質を向上させることで、言語の成熟度を高めた。

## 実装

- `src/parser/parser_cst.mbt` - `IntMinLiteralBoundary`, `MutableEnumFieldUnsupported` 診断
- `src/parser/parser_ast_expr.mbt` - 負リテラル境界判定、loop 式パース
- `src/parser/lexer.mbt` - コンテキスト依存キーワード処理
- `src/parser/format_test.mbt` - フォーマッタ round-trip テスト

## テスト

- `fixtures/typecheck/parse_let_annotation_colon.vibe` / `.diag` - let 型注釈パース
- `fixtures/typecheck/let_annotation_type_mismatch.vibe` / `.diag` - let 型注釈不一致
- `fixtures/typecheck/parse_loop_expr.vibe` / `.diag` - loop 式パース
- `fixtures/loop_expr_counter.vibe` - loop 式カウンタ
- `fixtures/typecheck/parse_int_min_literal_boundary.vibe` / `.diag` - Int 最小値境界
- `fixtures/typecheck/import_missing_from_keyword.vibe` / `.diag` - import `from` 欠落
- `fixtures/typecheck/import_malformed_separator.vibe` / `.diag` - import セパレータ不正
- `fixtures/typecheck/import_extra_comma.vibe` / `.diag` - import 余分カンマ
- `fixtures/modules/trait_chain_base.vibe` / `trait_chain_mid.vibe` - transitive trait import
- `fixtures/trait_import_chain.vibe` - trait import chain
- `fixtures/typecheck/polymorphic_recursion_unsupported.vibe` / `.diag` - 多相再帰診断
- `src/parser/format_test.mbt` - フォーマッタ回帰テスト
- `src/parser/syntax_kind_test.mbt` - コンテキスト依存キーワードテスト (`map { a: 1 }` → `map_kw`, `let map = 1` → `name`, `map(1)` → `name`)

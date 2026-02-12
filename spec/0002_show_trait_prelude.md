# Show Trait Prelude Migration

Status: accepted (2026-02-09)
Source: TODO.md "Show trait migration plan (prelude 常駐化)"

## 概要

`Show` trait を prelude に移動し、`Int/Float/Double/Bool/String` に対する組み込み impl を checker に追加した。`to_string` 関数は `[T: Show]` trait bound に依存するようになった。

## 決定事項

- checker prelude に `trait Show` と `Int/Float/Double/Bool/String` の impl を注入
- `to_string` を `[T: Show](x: T) -> String` として prelude 前提で提供
- `vibe/std/builtin_traits.vibe` および fixture 群から冗長な `trait Show` / primitive `impl Show` 宣言を削除
- unknown-bound 用 fixture は `MissingShow` エラーに切り替え

## 背景・理由

`Show` trait はほぼすべてのプログラムで利用される基本トレイトであり、ユーザーが毎回 import や宣言を行う負担を排除する必要があった。prelude 化により、`to_string` が暗黙に利用可能になり、std ライブラリの冗長な宣言も削減された。

## 実装

- `src/checker/typecheck_prelude.mbt` - prelude trait injection
- `vibe/std/builtin_traits.vibe` - `to_string = [T: Show](x: T) -> String { __to_string(x) }`

## テスト

- `fixtures/show_to_string_method.vibe` - Show trait + to_string メソッド呼び出し
- `fixtures/err_type_trait_impl_unknown_bound.vibe` - MissingShow unknown-bound エラー

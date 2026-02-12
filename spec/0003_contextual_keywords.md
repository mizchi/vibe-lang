# Contextual Keywords

Status: accepted (2026-02-09)
Source: TODO.md "P1 [done 2026-02-09]: Reduce keyword collision friction (for `map`) via contextual keyword handling"

## 概要

`map` をコンテキスト依存キーワードとして扱い、`map { ... }` はキーワード構文として維持しつつ、識別子位置（`let map = ...`、`map(...)`）では通常の名前としてレキシングするようにした。

## 決定事項

- `map` の後に `{` が続く場合は `map_kw` トークンとしてレキシング（マップリテラル構文）
- `let map = ...` や `map(...)` のような識別子位置では `name` トークンとしてレキシング
- lexer がコンテキスト（次のトークン）を見て判定を行う

## 背景・理由

`map` は配列操作等でよく使われる関数名であり、キーワード予約によって `let map = arr.map(f)` のような自然な命名が不可能になっていた。コンテキスト依存キーワード化により、マップリテラル構文との共存が実現された。

## 実装

- `src/parser/lexer.mbt` - コンテキスト依存キーワード判定ロジック

## テスト

- `src/parser/syntax_kind_test.mbt` - "lexer treats map as contextual keyword" テスト
  - `map { a: 1 }` -> `map_kw`
  - `let map = 1` -> `name`
  - `map(1)` -> `name`

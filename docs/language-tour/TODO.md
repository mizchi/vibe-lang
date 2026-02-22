# language-tour 改善 TODO

## 高優先度（サブエージェントが頻繁に必要とする）

- [x] H1: docs - Option[T] (Some/None) の説明を追加
- [x] H2: docs - Float/Double の演算・リテラル・関数を記載
- [x] H3: docs - ラベル付き引数 (~label: value) の説明を追加
- [x] H4: docs - プレースホルダー shorthand (_ + 1) の説明を充実（既存で十分）
- [x] H5: eval - Float/Double 演算のテストを追加
- [x] H6: eval - ラベル付き引数のテストを追加
- [x] H7: eval - プレースホルダー shorthand のテストを追加
- [x] H8: eval - Option の Some/None マッチのテストを追加

## 中優先度（中級ユーザ向け）

- [ ] M1: docs - derive() 構文の記載 — REPL で動作しない、skip
- [ ] M2: docs - open trait の記載 — REPL で動作しない、skip
- [x] M3: docs - エフェクト行変数 with { e } の記載
- [ ] M4: docs - suberror のユースケース例を追加 — REPL で throw 型エラー、skip
- [ ] M5: docs - モジュールシステム (use/export) の説明
- [x] M6: eval - trait bounds 付きジェネリクスのテストを追加
- [x] M7: docs/eval - map_get_or (安全なMapアクセス) を記載 + テスト追加

## 低優先度（実験的/高度な機能）

- [ ] L1: docs - perform/resume 継続セマンティクス
- [ ] L2: docs - Async/yield (--unstable-async)
- [ ] L3: docs - Threads API (--unstable-threads)
- [ ] L4: docs - Ref[T] スコープ安全性

## 整合性の問題

- [x] C1: builtins.md の HOF 引数順序を統一 (collection-first, fn-last)
- [x] C2: map_get_or を builtins.md に追加、from_jsonl/to_jsonl は既存

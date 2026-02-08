# xshell object pipeline memo

Status: draft memo for implementation planning.

## Goal

- POSIX サブセット互換を維持しつつ、Nushell/PowerShell 風の object pipeline を導入する。
- 既存の POSIX テキストパイプの挙動はデフォルトで壊さない。

## Core design

- パイプラインは 2 レーンに分離する。
- Text lane: `|` は文字列ストリーム専用。
- Object lane: `|>` は型付きオブジェクトストリーム専用。
- 外部コマンド境界は常に Text lane 契約に固定する。

## Boundary conversion

- Text -> Object は明示変換でのみ行う。
- 初期候補: `from_lines`, `from_json`, `from_jsonl`.
- Object -> Text も明示変換でのみ行う。
- 初期候補: `to_lines`, `to_json`, `to_jsonl`.
- 暗黙変換は行わない。

## Posix mode compatibility

- `--syntax posix` では POSIX 互換を優先する。
- POSIX 既存表現 (`|`, リダイレクト, クォート) は将来も最優先で保護する。
- object pipeline 機能は `|>` と明示変換 API でのみ有効化する。
- 既存 POSIX スクリプトの無変更実行を回帰要件にする。

## Current preview mapping

- `Runtime::eval_script_with_mode(..., PosixMode)` では command head を
  `sh_lines("<cmd>")` へデシュガーする。
- `where(xs, pred)` は `Array[String]` 用の first step として提供する。
- `sh_lines` は現状 `ls/cat/echo` サブセット実装。

## Non-goals (v0)

- `|` と `|>` の自動相互変換。
- 外部コマンド出力の自動スキーマ推論。
- POSIX 文法の曖昧領域への自動フォールバック。

## Invariants

- `|` は常に text pipe。
- `|>` は常に object pipe。
- 境界変換は明示 API のみ。
- 互換性回帰テストを CI で常時実行する。

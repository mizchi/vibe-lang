# PosixMode Command-Head Desugar Diagnostics

Status: accepted (2026-02-10)
Source: TODO.md "P0 [done 2026-02-10]: Add PosixMode command-head desugar diagnostics"

## 概要

`--syntax posix` モードにおいて、未解決のベア識別子がコマンドヘッドにデシュガーされる際、明示的なランタイムノートを出力するようにした。

## 決定事項

- `--syntax posix` で未解決のベア識別子（例: `ls`）は `sh_lines("ls")` にデシュガーされる
- デシュガー時に `note: posix-mode command-head desugar: ...` の明示的ノートを出力
- `run`/`shell-stdin` 出力でマイグレーション動作が可視化される

## 背景・理由

POSIX モードでは通常の変数参照とコマンド実行の区別が曖昧になりうる。暗黙のデシュガーが行われる場合にユーザーへ明示的に通知することで、予期しない動作の原因特定を容易にし、vibe 構文への移行を促進する。

## 実装

- `src/frontend/desugar.mbt` - `desugar_vibe_commands` 関数（PosixMode でのコマンドヘッドデシュガー）

## テスト

- `run`/`shell-stdin` 出力における `note: posix-mode command-head desugar` メッセージの確認

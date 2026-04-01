# ADR-0009: スクラッチワークフロー（インクリメンタル開発モデル）

- Date: 2026-02-16
- Status: accepted

## Context

探索的プログラミングにおいて、毎回ファイルを作成・編集するオーバーヘッドが大きい。Unison の codebase 方式を参考に、定義を逐次的に蓄積し、必要なタイミングでファイルに具象化するワークフローを検討した。

## Decision

`vibe eval` コマンドによるスクラッチワークフローを導入する:

```bash
vibe eval "let base = 10"                      # 定義を蓄積
vibe eval "let inc = (x: Int) -> Int { x + 1 }" # 前の定義を参照可能
vibe eval --db tmp.db --inspect-scope           # 現在のスコープを確認
vibe eval --export main.vibe                    # ファイルに具象化
```

主要コンポーネント:
- **名前空間ヘッド** — コンテンツハッシュで現在の定義状態を指す
- **index.vdb** — 永続メタデータ（graph_head, active_namespace, scratch.head）
- **具象化** — DAG → `.vibe` ファイルへの変換
- **履歴追跡** — ロールバック用の history_head（オプション）

## Consequences

- REPL とファイルベース開発の間を滑らかに行き来できる
- コンテンツアドレスモジュール（ADR-0004）との相性が良い
- `index.vdb` のロック管理が必要
- ワークフローの学習コストがある

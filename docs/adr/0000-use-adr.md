# ADR-0000: Architecture Decision Records を導入する

- Date: 2026-02-16
- Status: accepted

## Context

プロジェクトの設計判断が会話やコミットに散在しており、過去の意思決定の経緯を追跡しにくい。

## Decision

`docs/adr/` 配下に ADR（Architecture Decision Record）を連番で管理する。
フォーマットは `NNNN-slug.md`、テンプレートは `TEMPLATE.md` に従う。
`just adr` コマンドで新規 ADR のスキャフォールドを生成できるようにする。

## Consequences

- 意思決定の根拠が永続化され、後から参照可能になる
- 新規メンバーやコントリビュータがプロジェクトの設計背景を理解しやすくなる
- ADR の作成コストが若干増えるが、テンプレートとコマンドで軽減する

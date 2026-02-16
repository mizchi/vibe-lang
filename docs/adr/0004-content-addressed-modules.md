# ADR-0004: コンテンツアドレスモジュール（Unison スタイル）

- Date: 2026-02-16
- Status: accepted

## Context

従来のファイルパスベースのモジュールシステムでは、リネームや移動で参照が壊れる問題があった。また、同一コードの重複検出やキャッシュの一貫性を保証しにくい。Unison のコンテンツアドレス方式を参考にした。

## Decision

ソースコードを正規化し、SHA1 ハッシュで識別するモジュールシステムを採用する。

```
Source → Parse → AST → Normalize → S-expression → SHA1 hash
```

三層の参照を定義:
- **HashRef** (`#abc123`) — 不変のコンテンツアドレス（真の identity）
- **VersionRef** (`version@main`) — ミュータブルな名前空間ポインタ
- **SymbolRef** (`symbol@std/math`) — 人間が読める名前ポインタ

ランタイムは HashRef のみを使用し、VersionRef/SymbolRef はロック時に解決される。

## Consequences

- コード定義の同一性がハッシュで保証され、キャッシュとインクリメンタルビルドが堅牢になる
- リファクタリング（正規化後に同一であれば）がハッシュ不変で行える
- ユーザーにハッシュベースの概念モデルを理解してもらう学習コストがある
- `index.vdb` で状態管理が必要

# XS Language Documentation

## 概要
XS言語は、AIによる理解と生成を最適化するように設計された静的型付き関数型プログラミング言語です。このディレクトリには、言語の設計、実装、評価に関するすべてのドキュメントが含まれています。

## ドキュメント構成

### 設計ドキュメント (`design/`)
言語の設計思想と技術的な設計文書

- [Perceus Memory Management Design](design/perceus-memory-management-design.md) - Perceus参照カウント方式のメモリ管理設計
- [Recursion Syntax Design](design/recursion-syntax-design.md) - 再帰構文の設計
- [Salsa Integration Design](design/salsa-integration-design.md) - インクリメンタルコンパイルのためのSalsa統合
- [Effect System Design](design/EFFECT_SYSTEM_DESIGN.md) - エフェクトシステムの設計
- [Extensible Effects Design](design/EXTENSIBLE_EFFECTS_DESIGN.md) - 拡張可能エフェクトの設計
- [Module Design](design/MODULE_DESIGN.md) - モジュールシステムの設計
- [Runtime Architecture](design/RUNTIME_ARCHITECTURE.md) - ランタイムアーキテクチャ
- [WASM GC Backend Design](design/WASM_GC_BACKEND_DESIGN.md) - WebAssembly GCバックエンドの設計

### 実装ドキュメント (`implementation/`)
実装計画と進捗管理

- [Implementation Plan](implementation/IMPLEMENTATION_PLAN.md) - 全体の実装計画
- [TODO](implementation/TODO.md) - 実装タスクリスト
- [Refactoring Plan](implementation/REFACTORING_PLAN.md) - リファクタリング計画
- [Effect System Progress](implementation/EFFECT_SYSTEM_PROGRESS.md) - エフェクトシステムの実装進捗

### 評価ドキュメント (`evaluation/`)
言語の評価とテスト結果

- [AI Code Experience Evaluation](evaluation/AI_CODE_EXPERIENCE_EVALUATION.md) - AI開発体験の評価
- [Evaluation](evaluation/EVALUATION.md) - 言語全体の評価
- [Test AI Error Messages](evaluation/test_ai_error_messages.md) - AIフレンドリーなエラーメッセージのテスト

### その他のドキュメント
- [Policy](policy.md) - プロジェクトポリシー
- [My Idea](my-idea.md) - 言語のアイデアと構想

## 関連ドキュメント

### 言語仕様
- [README.md](../README.md) - プロジェクトの概要と基本的な使い方
- [CLAUDE.md](../CLAUDE.md) - AI向け言語としての詳細な特徴と仕様

### 実装コード
- `xs_core/` - 共通型定義、IR、ビルトイン関数
- `parser/` - S式パーサー
- `checker/` - HM型推論エンジン
- `interpreter/` - インタープリター
- `runtime/` - 統一ランタイムインターフェース
- `wasm_backend/` - WebAssembly GCコード生成

### サンプルコード
- `examples/` - 言語機能のサンプルコード
- `stdlib/` - 標準ライブラリ
- `tests/` - テストコード

## ドキュメントの貢献方法
1. 新しい機能を設計する場合は、`design/` に設計文書を追加
2. 実装タスクは `implementation/TODO.md` に追加
3. 評価結果は `evaluation/` に記録
4. このインデックスファイルを更新して、新しいドキュメントへのリンクを追加
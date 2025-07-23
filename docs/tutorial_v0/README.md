# XS言語チュートリアル v0

このディレクトリには、XS言語の基本的な使い方を学ぶためのチュートリアルが含まれています。

## 構成

- [00-index.md](00-index.md) - チュートリアルの目次とXS言語の概要
- [01-getting-started.md](01-getting-started.md) - 基本的な構文と使い方
- [02-pattern-matching.md](02-pattern-matching.md) - パターンマッチングの詳細
- [03-functional-programming.md](03-functional-programming.md) - 関数型プログラミングの概念
- [04-codebase-management.md](04-codebase-management.md) - コンテンツアドレス型コードベース管理

## サンプルコード

各章の練習問題の解答例は、`examples/` ディレクトリにあります：

- `examples/chapter1/` - 第1章の練習問題
- `examples/chapter2/` - 第2章の練習問題  
- `examples/chapter3/` - 第3章の練習問題
- `examples/chapter4/` - 第4章のサンプルプロジェクト

## 学習の進め方

1. **順番に読む**: 各章は前の章の知識を前提としているため、順番に読むことをお勧めします。

2. **コードを実行する**: 各章のサンプルコードは実際に実行できます。`xsc` コマンドを使って試してみてください。

3. **練習問題に挑戦**: 各章の最後にある練習問題を解いてみましょう。解答例と比較して理解を深めてください。

4. **実験する**: サンプルコードを変更したり、自分でコードを書いたりして、XS言語の動作を確認してください。

## 必要な環境

- Rust（最新の安定版）
- Git
- ターミナル/コマンドライン環境

## ビルド方法

```bash
# リポジトリのルートで
cargo build --release

# xscコマンドの実行
cargo run --bin xsc -- --help
```

## フィードバック

チュートリアルに関する質問や改善提案は、GitHubのIssuesまたはDiscussionsでお待ちしています。
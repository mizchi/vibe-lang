# XS言語 サンプルコード集

このディレクトリにはXS言語の機能を示すサンプルコードが含まれています。

## サンプルファイル

### basics.xs
- 基本的な算術演算
- 関数定義と適用
- let束縛
- 条件分岐
- リスト操作

### recursion.xs
- rec構文による再帰関数定義
- 階乗関数
- フィボナッチ数列

### adt-pattern.xs
- 代数的データ型の定義（Option型、Result型）
- パターンマッチング
- リストのパターンマッチング

### higher-order.xs
- 高階関数（map、filter、fold）
- 関数の合成
- ラムダ式の活用

### modules.xs
- モジュールの定義とエクスポート
- インポートの各種形式
- 修飾名でのアクセス

## 実行方法

各サンプルは以下のコマンドで実行できます：

```bash
# AST表示
xsc parse examples/basics.xs

# 型チェック
xsc check examples/recursion.xs

# 実行
xsc run examples/adt-pattern.xs
```

## テスト

より詳細な機能テストは `tests/feature_tests.rs` に含まれています。
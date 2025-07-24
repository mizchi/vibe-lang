# XS Language Examples

XS言語の機能を示すサンプルコード集です。

## ファイル一覧

### `module-test.xs`
モジュールシステムの使用例。モジュールの定義、エクスポート、インポートの方法を示します。

### `record-test.xs`
レコード型（オブジェクトリテラル）の使用例。レコードの作成、フィールドアクセス、ネストしたレコードの扱い方を示します。

### `rest-pattern-example.xs`
リストのrestパターンマッチング `(list x ...rest)` の使用例。

### `state-monad-example.xs`
ステートモナドの実装例。関数型プログラミングにおける状態管理の方法を示します。

### `list-operations-example.xs`
リスト操作関数（reverse, append, take, drop）の実装と使用例。

## 実行方法

各サンプルは以下のコマンドで実行できます：

```bash
cargo run -p xs-tools --bin xsc -- run xs/examples/ファイル名.xs
```

例：
```bash
cargo run -p xs-tools --bin xsc -- run xs/examples/record-test.xs
```
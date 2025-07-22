# XS Test Files Classification

## テスト分類

### 1. 正式なテストコード (tests/xs_tests に移動済み)
- `core-functions-test.xs` - コア関数のテスト
- `parser-tests.xs` - パーサーのテスト
- `self-hosting/` - セルフホスティング関連のテスト

### 2. サンプルコード (examples/ に移動すべき)
- `module-test.xs` - モジュールシステムの使用例
- `record-test.xs` - レコード型の使用例
- `simple-rest-pattern.xs` - restパターンマッチの使用例
- `state-monad-test.xs` - ステートモナドの実装例
- `list-extras-test.xs` - リスト操作関数の使用例

### 3. テストランナー実装 (保持または統合)
- `test-runner.xs` - メインのテストランナー
- `simple-test-runner.xs` - シンプルなテストランナー
- `working-test-runner.xs` - 動作確認済みテストランナー
- `result-test-runner.xs` - Result型ベースのテストランナー

### 4. 開発中の実験的コード (整理・削除候補)
- `result-*.xs` - Result型の実験的実装
- `minimal-*.xs` - 最小限のテストケース
- `simple-*.xs` - 個別機能の動作確認

### 5. 削除候補
- 重複したファイル
- 一時的な動作確認ファイル
- 未完成の実装

## アクション計画

1. **examples/ディレクトリの作成**
   - サンプルコードを整理して移動

2. **テストの統合**
   - 同じ機能の重複テストを統合
   - テストランナーの実装を1つに統合

3. **削除**
   - 一時的な実験ファイル
   - 重複ファイル
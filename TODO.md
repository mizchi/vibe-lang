# TODO

## 既存のアイデア

- [x] 配列のパターンマッチ `[]`, `[head, ...tail]` を導入する ✅
  - パーサー、型チェッカー、インタープリターすべてで実装済み
  - `(list h ... t)` 形式でhead/tailパターンマッチが可能
- [x] リテラルの中に `{ x: 1 }` のようなオブジェクトリテラルを導入する ✅
  - レコード型として既に実装済み
  - `{ name: "Alice", age: 30 }` のような構文でレコードを作成
  - `person.name` のようなドット記法でフィールドアクセス可能
- [ ] Rust のように、実装と同じファイルで In Source Testing ができる
  - 検討の結果、S式ベースの言語では標準ライブラリとして実装するのが適切
  - 将来的には、テストフレームワーク（xs-test）の拡張として実装予定

## 実装完了 ✅

### 最近完了した機能
- ✅ lowerCamelCase命名規則の強制（ハイフンを禁止）
- ✅ 階層的な名前空間システム（Unison UCM風）
- ✅ 関数単位の依存関係追跡
- ✅ ASTコマンドによる構造的変換
- ✅ インクリメンタル型チェック
- ✅ 差分テスト実行システム
- ✅ 配列のパターンマッチ（`(list h ... t)` 形式）
- ✅ レコード（オブジェクトリテラル）とフィールドアクセス

## 今後の実装計画（AI時代の言語設計）

### Phase 1: コード検索の強化 (1-2週間) 🔍 【最優先】

#### AST/型によるクエリシステム
- [ ] 型パターンによる検索（例: "Int -> Int型の関数を全て検索"）
- [ ] AST構造による検索（例: "match式を含む関数"）
- [ ] 依存関係による検索（DependsOn/DependedBy）
- [ ] REPLでの検索コマンド（`search`, `find`）
- [ ] 検索結果の構造化表示

```lisp
; 使用例
xs> search type:(-> Int Int)
xs> find ast:match
xs> search dependsOn:Math.fibonacci
```

### Phase 2: 構造化シェルの拡張 (2-3週間) 🐚

#### nushell風のパイプライン処理
- [ ] パイプライン演算子 `|` の実装
- [ ] 構造化データの変換関数（filter, map, sort, where）
- [ ] inspectコマンドで詳細情報表示
- [ ] JSON/YAML形式での入出力

```lisp
; 使用例
xs> definitions 
    | filter (fn (d) (isFunction d.type))
    | map (fn (d) d.name)
    | sort

xs> inspect Math.fibonacci
{
  hash: "abc123...",
  type: "(-> Int Int)",
  dependencies: ["Math.add"],
  metadata: { ... }
}
```

### Phase 3: Effect System (3-4週間) 🎯 【高優先】

#### 副作用の型レベル追跡
- [ ] Effect型の定義（IO, Network, FileSystem等）
- [ ] 関数からのEffect推論
- [ ] Effect注釈の構文
- [ ] 純粋関数との明確な区別

```lisp
; Effect注釈の例
(effect IO
  (print : (-> String (IO Unit)))
  (read : (-> (IO String))))

(let readAndPrint : {IO} Unit
  (fn ()
    (let input (perform read))
    (perform (print input))))
```

### Phase 4: 実行権限システム (2週間) 🔒

#### Effect推論からの権限導出
- [ ] Permission型の定義
- [ ] Effect→Permission自動変換
- [ ] CLIでの権限指定（--allow-io, --deny-net等）
- [ ] サンドボックス実行環境

```bash
# 実行例
xs run --deny-io program.xs  # IOエフェクトがあればエラー
xs run --allow-read=/tmp program.xs  # /tmpのみ読み取り許可
```

### Phase 5: AI統合の強化 (継続的) 🤖

#### MCPプロトコル対応
- [ ] 型情報の直接提供API
- [ ] AST操作API（ASTコマンドの拡張）
- [ ] 依存関係グラフAPI
- [ ] インクリメンタル更新通知

#### AI向け機能
- [ ] 関数の使用例自動生成
- [ ] 型シグネチャからの説明生成
- [ ] エラーからの自動修正提案
- [ ] テスト失敗からの実装推論

## その他の改善項目

### 標準ライブラリ
- [ ] IO操作（ファイル読み書き）
- [ ] ネットワーク操作
- [ ] JSON/YAMLパーサー
- [ ] 正規表現
- [ ] 日付/時刻操作

### 開発者体験
- [ ] LSP (Language Server Protocol) サポート
- [ ] デバッガー統合
- [ ] より詳細なプロファイラー

### パフォーマンス
- [ ] 型チェッカーの更なる高速化
- [ ] WebAssemblyコード生成の最適化

# use lib 機能のテスト手順

## XS Shell での使用方法

```bash
cargo run -p xs-tools --bin xs-shell
```

## テストケース

### 1. 基本的な use lib
```
xs:scratch> (use lib)
```
これで `concat`, `cons` などの標準ライブラリ関数が使えるようになります。

### 2. String モジュールのインポート
```
xs:scratch> (use lib/String)
```
これで `concat`, `length`, `toInt`, `fromInt` が使えるようになります。

### 3. 特定の関数のみインポート
```
xs:scratch> (use lib/String (concat length))
```
`concat` と `length` のみが使えるようになります。

### 4. 実際の使用例
```
xs:scratch> (use lib/String)
xs:scratch> concat "Hello, " "World!"
```
期待される結果: `"Hello, World!" : String`

```
xs:scratch> length "Hello"
```
期待される結果: `5 : Int`

## 注意事項

1. **scratch 名前空間**: デフォルトで `(use lib)` が自動的に実行されます
2. **パス形式**: `lib/String` のようにスラッシュで区切ります
3. **選択的インポート**: `(concat length)` のように括弧内に関数名を列挙します

## 実装の詳細

- `use` 式は型チェック時に処理され、指定された関数を現在の環境に追加します
- ランタイムでは単位値（`Int(0)`）を返します
- 各名前空間は独立した環境を持ちます
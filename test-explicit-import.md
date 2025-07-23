# 明示的インポートシステムのテスト

## テスト手順

```bash
cargo run -p xs-tools --bin xs-shell
```

## 1. デフォルトではライブラリ関数は使えない

```
xs:scratch> concat "Hello" " World"
```
期待される結果: `Error: Undefined variable: concat`

```
xs:scratch> cons 1 (list)
```
期待される結果: `Error: Undefined variable: cons`

## 2. use lib でライブラリをインポート

```
xs:scratch> (use lib)
xs:scratch> id 42
```
期待される結果: `42 : Int`

## 3. モジュールから特定の関数のみインポート

```
xs:scratch> (use lib/String (concat length))
xs:scratch> concat "Hello" " World"
```
期待される結果: `"Hello World" : String`

```
xs:scratch> length "Hello"
```
期待される結果: `5 : Int`

```
xs:scratch> toInt "123"
```
期待される結果: `Error: Undefined variable: toInt` (インポートしていないため)

## 4. モジュール全体をインポート

```
xs:scratch> (use lib/String)
xs:scratch> toInt "123"
```
期待される結果: `123 : Int`

```
xs:scratch> fromInt 42
```
期待される結果: `"42" : String`

## 5. 修飾名は使えない

```
xs:scratch> String.concat "a" "b"
```
期待される結果: `Error: Undefined variable: String.concat`

## まとめ

- ESM/Pythonのように、明示的なインポートが必須
- `use lib/Module` でモジュール全体をインポート
- `use lib/Module (func1 func2)` で特定の関数のみインポート
- 修飾名（`String.concat`）は廃止され、インポート後は直接関数名でアクセス
- スコープが明確になり、どの関数がどこから来ているかが分かりやすい
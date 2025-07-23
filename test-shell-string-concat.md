# String.concat のテスト手順

## シェルの起動
```bash
cargo run -p xs-tools --bin xs-shell
```

## テスト手順

### 1. 基本的な String.concat のテスト
```
xs:scratch> String.concat "Hello, " "World!"
```
期待される結果: `"Hello, World!" : String`

### 2. repeatString 関数の定義（シェルで入力）
```
xs:scratch> (let repeatString (fn (s: String n: Int)
  (if (= n 0)
      ""
      (String.concat s (repeatString s (- n 1))))))
```
注意: この定義はエラーになるはずです（再帰呼び出しで未定義変数）

### 3. rec を使った正しい定義
```
xs:scratch> (rec repeatString (s: String n: Int)
  (if (= n 0)
      ""
      (String.concat s (repeatString s (- n 1)))))
```

### 4. 関数の実行
```
xs:scratch> repeatString "Hi" 3
```
期待される結果: `"HiHiHi" : String`

```
xs:scratch> repeatString "XS " 2
```
期待される結果: `"XS XS " : String`

### 5. その他の String モジュール関数のテスト
```
xs:scratch> String.length "Hello"
```
期待される結果: `5 : Int`

```
xs:scratch> String.fromInt 42
```
期待される結果: `"42" : String`

```
xs:scratch> String.toInt "123"
```
期待される結果: `123 : Int`
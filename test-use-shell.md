# XS Shell での use lib/String テスト

## テスト手順

```bash
cargo run -p xs-tools --bin xs-shell
```

## テストケース

### 1. lib/String モジュールをインポート
```
xs:scratch> (use lib/String)
```

### 2. concat 関数を使用
```
xs:scratch> concat "Hello, " "World!"
```
期待される結果: `"Hello, World!" : String`

### 3. 再帰関数の定義
```
xs:scratch> (rec repeatString (s: String n: Int)
  (if (= n 0)
      ""
      (concat s (repeatString s (- n 1)))))
xs:scratch> repeatString "Hi" 3
```
期待される結果: `"HiHiHi" : String`

### 4. 特定の関数のみインポート
```
xs:scratch> (use lib/String (concat length))
xs:scratch> length "test"
```
期待される結果: `4 : Int`
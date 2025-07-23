# XS Shell 新機能テスト手順

## シェルの起動
```bash
cargo run -p xs-tools --bin xs-shell
```

## テスト手順

### 1. 名前空間の確認
```
xs:scratch> namespace
```
現在の名前空間が `scratch` と表示されることを確認

### 2. 関数の定義と再定義警告のテスト

#### 初回定義
```
xs:scratch> (let double (fn (x) (* x 2)))
```
通常の定義として表示される

#### 同じ実装での再定義
```
xs:scratch> (let double (fn (x) (* x 2)))
```
"Definition unchanged (same implementation)" と表示される

#### 異なる実装での再定義
```
xs:scratch> (let double (fn (x) (* 2 x)))
```
"Updated existing definition (previous definition: [hash])" と表示される

### 3. Float演算のテスト
```
xs:scratch> (let celsiusToFahrenheit (fn (c: Float) (+ (* c 1.8) 32.0)))
xs:scratch> (celsiusToFahrenheit 0.0)
```
結果: 32.0

### 4. モジュロ演算子のテスト
```
xs:scratch> (let isEven (fn (n: Int) (= (% n 2) 0)))
xs:scratch> (isEven 4)
```
結果: true

### 5. 名前空間の切り替え
```
xs:scratch> namespace myproject
xs:myproject> (let triple (fn (x) (* x 3)))
xs:myproject> namespace scratch
xs:scratch>
```

## 期待される動作

1. **デフォルト名前空間**: シェル起動時は自動的に `scratch` 名前空間
2. **プロンプト表示**: `xs:名前空間名>` の形式
3. **再定義警告**: 
   - 同じ実装: cyan色で "Definition unchanged"
   - 異なる実装: yellow色で "Updated existing definition"
4. **Float演算**: Int と Float 両方で算術演算子が動作
5. **モジュロ演算子**: `%` が正しく動作
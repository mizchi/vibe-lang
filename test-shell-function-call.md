# シェルモードでの関数呼び出しテスト

## テスト方法
```bash
cargo run -p xs-tools --bin xs-shell
```

## テストケース

### 1. 関数定義
```
xs:scratch> (let double (fn (x) (* x 2)))
```

### 2. 括弧なし関数呼び出し（新機能）
```
xs:scratch> double 21
```
期待される結果: `42 : Int`

### 3. 複数引数の関数
```
xs:scratch> (let add (fn (x y) (+ x y)))
xs:scratch> add 3 4
```
期待される結果: `7 : Int`

### 4. Float型の関数呼び出し
```
xs:scratch> (let celsiusToFahrenheit (fn (c: Float) (+ (* c 1.8) 32.0)))
xs:scratch> celsiusToFahrenheit 0.0
```
期待される結果: `32.0 : Float`

### 5. Bool型の関数呼び出し
```
xs:scratch> (let isEven (fn (n: Int) (= (% n 2) 0)))
xs:scratch> isEven 4
xs:scratch> isEven 5
```
期待される結果:
- `true : Bool`
- `false : Bool`

### 6. 従来のS式形式も引き続き動作
```
xs:scratch> (double 21)
xs:scratch> (add 3 4)
```

## 注意事項

1. **シェルコマンドとの区別**: `ls`, `search`, `filter` などの予約されたシェルコマンドは、引き続きシェルコマンドとして解釈されます。

2. **単一の識別子**: 引数なしの場合は、関数の参照として扱われます：
   ```
   xs:scratch> double
   <closure> : (-> Int Int)
   ```

3. **混在構文**: S式と括弧なし呼び出しを混在できます：
   ```
   xs:scratch> add (double 5) 10
   ```
   期待される結果: `20 : Int`
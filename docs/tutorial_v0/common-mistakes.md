# よくある間違いと注意点

## 関数呼び出しには括弧が必要

XS言語はS式ベースのため、関数呼び出しには必ず括弧が必要です。

### 間違い
```
xs> isEven 1
<closure> : (-> Int Bool)  ; isEven関数が返される（1は無視される）
```

### 正しい
```
xs> (isEven 1)
false : Bool
```

### 理由
- `isEven 1` は2つの独立した式として解釈されます
- 関数を値として参照する場合と、関数を呼び出す場合が明確に区別されます
- これにより、関数を第一級の値として扱えます

### 他の例
```
; 関数の参照（値として）
xs> double
<closure> : (-> Int Int)

; 関数の呼び出し
xs> (double 5)
10 : Int

; 部分適用
xs> (let add (fn (x y) (+ x y)))
xs> (let add5 (add 5))     ; 部分適用
xs> (add5 3)                ; 結果: 8
```

## 型注釈の位置

型注釈は変数名の直後に書きます：

### 正しい
```
(let x: Int 42)
(fn (n: Int) (* n 2))
```

### 間違い
```
(let Int x 42)      ; エラー
(fn (Int n) (* n 2)) ; エラー
```

## Float演算での型の一致

算術演算子は同じ型同士でしか使えません：

### 間違い
```
xs> (+ 1 2.0)
Error: + requires arguments of the same numeric type
```

### 正しい
```
xs> (+ 1.0 2.0)
3.0 : Float

xs> (+ 1 2)
3 : Int
```
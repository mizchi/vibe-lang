# $ 演算子 - 括弧の代替構文

## 概要

`$`演算子は、Haskellから借用した構文糖で、括弧を減らすために使用されます。

## 基本原則

**`f $ expr` は `f (expr)` と完全に同一です。**

## 特性

1. **最低優先順位** - すべての演算子より優先順位が低い
2. **右結合** - `f $ g $ h x` は `f (g (h x))` として解釈
3. **純粋な構文糖** - ASTレベルでは通常の関数適用と同じ

## 使用例

### 良い使用例

```vibe
# 深いネストを避ける
print $ show $ calculate $ getData
# 同じ: print (show (calculate (getData)))

# 算術式の結果を渡す
sqrt $ x * x + y * y
# 同じ: sqrt (x * x + y * y)

# 条件式の結果を渡す
process $ if ready { getData } else { waitForData }
# 同じ: process (if ready { getData } else { waitForData })
```

### 悪い使用例

```vibe
# 不要な使用（括弧が不要な場合）
print $ x       # print x で十分
double $ 5      # double 5 で十分
f $ g          # f g で十分
```

## 実装詳細

- パース時に通常の`Apply`ノードに変換
- 特別なAST要素は不要
- `parse_dollar`関数で右結合を実現

## パイプライン演算子との使い分け

- `|>` : データ変換の流れを表現（左から右）
- `$` : 括弧の削減（右から左）

```vibe
# パイプライン: データの流れ
data |> filter valid |> map transform |> sum

# ドル: 括弧の削減
print $ "Result: " ++ show result

# 組み合わせ
print $ data
  |> filter valid
  |> map transform
  |> join ", "
```
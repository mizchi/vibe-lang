# Vibe言語の演算子設計提案

## 現状の分析

### パイプライン演算子 `|>`
- **目的**: データ変換の流れを表現
- **AST**: `Pipeline`ノード
- **結合性**: 左結合
- **優先順位**: 中程度

### ドル演算子 `$`
- **目的**: 括弧を減らす
- **AST**: `Apply`ノード（通常の関数適用と同じ）
- **結合性**: 右結合  
- **優先順位**: 最低

## 使い分けの指針

### 1. 必須ではないが便利な場合

#### `|>` が自然なケース
```vibe
# データ処理のパイプライン
data
  |> validate
  |> transform
  |> save

# メソッドチェーン風
user
  |> getName
  |> toUpperCase
  |> trim
```

#### `$` が自然なケース
```vibe
# 単純な括弧の削減
print $ "Result: " ++ show result

# 条件式の結果を渡す
process $ if ready { getData } else { waitForData }
```

### 2. どちらも不要なケース

```vibe
# シンプルな関数適用
double 5
add 1 2

# 2段階程度のネスト（括弧の方が分かりやすい）
double (inc 5)
print (getName user)
```

### 3. 混在使用のパターン

```vibe
# 外側は$、内側は|>（推奨）
print $ data
  |> filter valid
  |> map transform
  |> join ", "

# 逆は避ける（読みにくい）
data |> process |> (print $ format)  # 悪い例
```

## 提案1: 現状維持

### メリット
- 両方の演算子が使える柔軟性
- Haskellユーザーに馴染みやすい`$`
- F#/Elmユーザーに馴染みやすい`|>`

### デメリット
- 同じことを表現する方法が複数ある
- スタイルガイドが必要

## 提案2: `|>`のみを推奨

### メリット
- 統一されたスタイル
- データフローが明確
- 学習コストが低い

### デメリット
- 括弧を避けたい場面で不便
- 関数合成が表現しにくい

### 実装変更案
```vibe
# $を廃止し、|>の優先順位を調整
print (1 + 2)           # 括弧必須
1 + 2 |> print          # |>を使う

# または、|>の右側で式を許可
print |> (1 + 2)        # 新しい構文？
```

## 提案3: 用途別に明確に分離

### ルール
1. `|>` はデータ変換のみ
2. `$` は括弧の代替のみ
3. 混在は1行につき1種類まで

### 良い例
```vibe
# |> for data transformation
[1, 2, 3]
  |> filter even
  |> map double
  |> sum

# $ for reducing parentheses  
print $ "Total: " ++ show total
maybe defaultValue id $ lookup key map
```

### 悪い例
```vibe
# 混在しすぎ
x |> f $ g |> h  # 避ける
```

## 提案4: セマンティックな違いを導入

### 案
- `|>` : 値の変換（副作用なし）
- `$` : 関数適用（副作用あり）

```vibe
# Pure transformations use |>
numbers
  |> filter positive
  |> map square
  |> sum

# Effects use $
print $ result
writeFile filename $ content
performIO $ action
```

## 推奨案: 提案3（用途別分離）

理由：
1. 両方の利点を活かせる
2. 明確なガイドラインで混乱を防げる
3. 既存のコードとの互換性

### スタイルガイド

```vibe
# ✓ 良い: データ変換には|>
result = input
  |> parse
  |> validate
  |> process

# ✓ 良い: 括弧削減には$
log $ "Processing " ++ filename
sqrt $ x*x + y*y

# ✗ 悪い: 不必要な使用
x |> double      # double x で十分
print $ x        # print x で十分

# ✗ 悪い: 過度な混在
f $ g |> h $ x   # 読みにくい
```

### 優先順位表（最終案）

```
1. $     （最低、右結合）
2. |>    （低、左結合）
3. ||    （論理OR、左結合）
4. &&    （論理AND、左結合）
5. ==, !=, <, >, <=, >= （比較、左結合）
6. ++, :: （リスト操作、右結合）
7. +, -  （加減、左結合）
8. *, /, % （乗除、左結合）
9. 関数適用 （最高、左結合）
```

この優先順位により：
- `print $ 1 + 2` → `print (1 + 2)`
- `x |> f $ g y` → `x |> f (g y)`
- `f $ x |> g |> h` → `f (x |> g |> h)`
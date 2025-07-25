# パイプライン演算子 |> と $ 演算子の使い分けパターン

## 1. データ変換のチェーン

### パイプライン演算子を使う場合
```vibe
# データの流れを左から右へ表現
[1, 2, 3, 4, 5]
  |> filter even
  |> map double
  |> sum

# 読み方：リストを偶数でフィルタして、2倍にして、合計する
```

### $ 演算子を使う場合
```vibe
# 関数の適用を右から左へ表現
sum $ map double $ filter even $ [1, 2, 3, 4, 5]

# 読み方：sumを適用する（map doubleを適用する（filter evenを適用する（リストに）））
```

### 括弧を使う場合
```vibe
sum (map double (filter even [1, 2, 3, 4, 5]))
```

## 2. 単一の関数適用

### $ が有用な場合
```vibe
# 算術式の結果を関数に渡す
print $ 1 + 2 * 3            # print (1 + 2 * 3)
sqrt $ x * x + y * y         # sqrt (x * x + y * y)
```

### |> でも可能だが冗長
```vibe
(1 + 2 * 3) |> print
(x * x + y * y) |> sqrt
```

### 括弧で十分な場合
```vibe
print (1 + 2 * 3)
sqrt (x * x + y * y)
```

## 3. 部分適用との組み合わせ

### パイプラインが自然な場合
```vibe
numbers
  |> filter (greaterThan 5)    # x > 5
  |> map (multiply 2)          # x * 2
  |> foldLeft add 0            # 累積和
```

### $ だと読みにくい場合
```vibe
foldLeft add 0 $ map (multiply 2) $ filter (greaterThan 5) $ numbers
```

## 4. ネストした関数適用

### $ が便利な場合
```vibe
# 各ステップが独立した関数適用
validate $ normalize $ parse $ input

# if-else の結果を関数に渡す
process $ if flag { getData } else { getDefault }
```

### |> の方が自然な場合
```vibe
input
  |> parse
  |> normalize
  |> validate
```

## 5. 混在パターン

### 両方を組み合わせる
```vibe
# メインの流れは |>、部分的に $
data
  |> preprocess
  |> map $ fn x -> transform $ x + offset
  |> postprocess

# 外側は $、内側は |>
print $ data |> process |> format
```

## 6. 関数合成

### $ を使った合成
```vibe
# 関数を組み合わせて新しい関数を作る
let processLine = trim $ toLowerCase $ stripComments
```

### |> では表現しにくい
```vibe
# これは関数ではなく、値の処理になってしまう
let result = line |> stripComments |> toLowerCase |> trim
```

## 7. 複雑な式

### $ で括弧を減らす
```vibe
maybe defaultValue id $ lookup key $ parseConfig $ readFile filename
```

### |> で段階的に処理
```vibe
filename
  |> readFile
  |> parseConfig
  |> lookup key
  |> maybe defaultValue id
```

## 8. 関数の引数として

### $ が有効な場合
```vibe
# 関数の引数に複雑な式を渡す
forEach (print $ formatNumber 2) $ generateSequence 1 100
```

### |> だと構造が変わる
```vibe
generateSequence 1 100
  |> forEach (fn x -> x |> formatNumber 2 |> print)
```

## 推奨される使い分け

### |> を使うべき場合
1. データの変換パイプライン
2. 段階的な処理の流れを表現
3. メソッドチェーンのような書き方をしたい
4. 各ステップが明確に分かれている

### $ を使うべき場合
1. 単一の関数適用で括弧を避けたい
2. 関数合成を表現したい
3. 右から左への評価順序が自然
4. ネストが深い関数適用

### どちらも使わない場合
1. シンプルな関数適用は括弧で十分
2. 2段階程度のネストなら括弧の方が明確
3. 可読性を損なう場合

## 提案：演算子の優先順位と結合性

```
優先順位（低い順）：
1. $ （右結合）
2. |> （左結合）
3. || （左結合）
4. && （左結合）
5. ==, != （左結合）
6. <, >, <=, >= （左結合）
7. ::, ++ （右結合）
8. +, - （左結合）
9. *, /, % （左結合）
10. 関数適用（左結合）
```

この優先順位により、以下のような式が可能：
```vibe
# $ と |> の組み合わせ
result $ input |> process |> validate

# これは以下と同じ
result (input |> process |> validate)

# 複雑な例
print $ users 
  |> filter active 
  |> map getName
  |> join ", "
```
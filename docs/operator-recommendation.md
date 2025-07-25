# Vibe言語における演算子使用の推奨事項

## 基本方針

**両方の演算子を維持し、用途に応じて使い分ける**

## 使用ガイドライン

### 1. デフォルトは括弧または直接適用

```vibe
# シンプルな場合は演算子不要
double 5
print message
add x y
```

### 2. パイプライン演算子 `|>` を使う場面

**データの変換フロー**を表現する時：

```vibe
# ✓ 良い例：3段階以上の変換
users
  |> filter isActive
  |> map getName  
  |> sort
  |> take 10

# ✗ 悪い例：単純すぎる
x |> double  # double x で十分
```

### 3. ドル演算子 `$` を使う場面

**括弧のネストを避けたい**時：

```vibe
# ✓ 良い例：深いネストの回避
print $ "Sum: " ++ show $ sum $ map double numbers
# 上記は以下と完全に同じ：
print ("Sum: " ++ show (sum (map double numbers)))

# ✓ 良い例：条件式の結果を渡す
process $ if ready { getData } else { getDefault }
# 上記は以下と完全に同じ：
process (if ready { getData } else { getDefault })

# ✗ 悪い例：不要な使用
print $ x  # print x で十分
```

**重要**: `$`演算子はパース時に括弧として扱われます。
`f $ x + y`は`f (x + y)`として解釈されます。

### 4. 組み合わせのルール

```vibe
# ✓ 推奨：外側に$、内側に|>
print $ data
  |> process
  |> format

# ✗ 非推奨：過度な混在
f $ g |> h $ x  # 読みにくい
```

## まとめ

- **必要な時だけ**使う（YAGNI原則）
- **意図を明確に**する道具として使う
- **可読性**を最優先に考える

## チートシート

```vibe
# 変換の連鎖 → |>
data |> validate |> transform |> save

# 括弧の削減 → $
sqrt $ x*x + y*y

# それ以外 → 使わない
double 5  # OK
add x y   # OK
```
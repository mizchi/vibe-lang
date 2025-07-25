# Vibe言語への $ 演算子導入提案

## 概要
Haskellの `$` 演算子と同様の機能をVibe言語に導入する。

## 仕様

### 優先順位
- 最低優先順位（すべての演算子より低い）
- 右結合

### 構文
```
expr1 $ expr2
```

### セマンティクス
`f $ x` は `f x` と同じだが、`$` の右側の式全体が引数として扱われる。

## 例

```vibe
# 基本的な使用
print $ 1 + 2          # print (1 + 2)
map double $ [1, 2, 3] # map double [1, 2, 3]

# ネストした使用
print $ map double $ filter isEven $ [1, 2, 3, 4, 5]
# 等価: print (map double (filter isEven [1, 2, 3, 4, 5]))

# 演算子との組み合わせ
f $ x + y * z  # f (x + y * z)
f x $ g y      # (f x) (g y)
```

## 実装案

### パーサーの変更

1. 新しいパース関数 `parse_dollar` を追加
2. パース階層を変更：
   - `parse_expression` → `parse_dollar`
   - `parse_dollar` → `parse_infix`
   - `parse_infix` → `parse_pipeline`
   - など

### コード例
```rust
fn parse_expression(&mut self) -> Result<Expr, XsError> {
    self.parse_dollar()
}

fn parse_dollar(&mut self) -> Result<Expr, XsError> {
    let mut left = self.parse_infix()?;
    
    while matches!(self.current_token, Some((Token::Dollar, _))) {
        self.advance()?; // consume '$'
        self.skip_newlines();
        
        // $ は右結合なので、残り全体をパース
        let right = self.parse_dollar()?;
        
        left = Expr::Apply {
            func: Box::new(left),
            args: vec![right],
            span: Span::new(left.span().start, self.position()),
        };
    }
    
    Ok(left)
}
```

## メリット

1. **括弧の削減**: 深くネストした関数適用を読みやすく書ける
2. **パイプラインスタイル**: データの流れを左から右に書ける
3. **Haskellとの親和性**: Haskellユーザーに馴染みやすい

## デメリット

1. **新しい演算子の学習コスト**
2. **既存のコードとの互換性**: `$` を変数名に使っている場合
3. **パース規則の複雑化**

## 代替案

### 1. パイプライン演算子の拡張
既存の `|>` をより柔軟にする

### 2. 括弧の省略規則
特定の文脈で括弧を省略できるようにする

### 3. 現状維持
括弧を使い続ける（最もシンプル）
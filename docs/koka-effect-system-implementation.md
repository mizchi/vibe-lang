# Koka風エフェクトシステムの実装

## 概要

Vibe言語にKoka言語風のエフェクトシステムを実装しました。この実装により、以下の機能が利用可能になりました：

1. **エフェクト定義とハンドリング**
2. **do記法のエフェクトベース変換**
3. **with/handler構文**
4. **perform構文によるエフェクト実行**
5. **row-polymorphicなエフェクトシステム**

## 主要コンポーネント

### 1. 正規化AST (`normalized_ast.rs`)

異なる構文形式を統一的に扱うための正規化されたAST表現：

```rust
pub enum NormalizedExpr {
    Literal(Literal),
    Var(String),
    Apply { func: Box<NormalizedExpr>, arg: Box<NormalizedExpr> },
    Lambda { param: String, body: Box<NormalizedExpr> },
    Let { name: String, value: Box<NormalizedExpr>, body: Box<NormalizedExpr> },
    Perform { effect: String, operation: String, args: Vec<NormalizedExpr> },
    Handle { expr: Box<NormalizedExpr>, handlers: Vec<NormalizedHandler> },
    // ...
}
```

### 2. Kokaエフェクトシステム (`koka_effects.rs`)

Koka風のエフェクトシステムの実装：

```rust
pub struct EffectRow {
    pub effects: BTreeSet<EffectType>,
    pub row_var: Option<String>,  // for polymorphism
}

pub enum EffectType {
    IO,
    State(String),
    Exn(String),
    Async,
    // ...
}
```

### 3. エフェクト正規化 (`effect_normalizer.rs`)

エフェクトの推論と正規化：

```rust
impl EffectNormalizer {
    pub fn infer_effects(&self, expr: &NormalizedExpr) -> BTreeSet<String> {
        // エフェクトを推論
    }
    
    pub fn normalize_with_effects(&self, expr: NormalizedExpr) -> (NormalizedExpr, EffectRow) {
        // エフェクト情報を含めて正規化
    }
}
```

## 使用例

### 1. perform構文

```vibe
perform IO.print "Hello, World!"
```

### 2. with/handler構文

```vibe
with stateHandler {
    x <- perform State.get;
    perform State.put (x + 1);
    perform State.get
}
```

### 3. handle式

```vibe
handle {
    perform IO.print "test"
} {
    IO.print msg k -> k ()
}
```

### 4. do記法（エフェクトコンテキスト）

```vibe
do {
    x <- readLine;
    y <- readLine;
    print (x ++ y)
}
```

## GLLパーサーの拡張

GLLパーサーに以下の構文規則を追加：

- `WithExpr -> with Handler { Expr }`
- `DoExpr -> do { DoStatements }`
- `HandleExpr -> handle { Expr } { HandlerCases }`
- `PerformExpr -> perform EffectOp AtomExprs`
- `EffectOp -> TypeName . Ident | Ident . Ident`

## 実装のポイント

1. **コンテンツアドレシング**: 正規化されたASTは決定論的にハッシュ可能
2. **段階的変換**: Surface AST → Normalized AST → Typed IR → Optimized IR
3. **エフェクト多相**: row-polymorphismによる柔軟なエフェクト合成
4. **Kokaスタイルのハンドラー**: 継続ベースのエフェクトハンドリング

## 今後の拡張

1. **エフェクト推論の完全実装**
2. **エフェクトハンドラーの最適化**
3. **より多くの組み込みエフェクト**
4. **エフェクトベースの並行処理**
5. **エフェクトシステムのベンチマーク**

## テスト

統合テストにより、以下の機能が正しく動作することを確認：

- perform式の正規化
- エフェクト推論
- handle式の構築
- エフェクトrowの操作
- レコード形式のハンドラー変換

## 参考文献

- [Koka Language](https://koka-lang.github.io/)
- [Programming with Effect Handlers and FBIP in Koka](https://www.microsoft.com/en-us/research/uploads/prod/2023/07/fbip.pdf)
- [Algebraic Effects for the Rest of Us](https://overreacted.io/algebraic-effects-for-the-rest-of-us/)
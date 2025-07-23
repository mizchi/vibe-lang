# XS言語の再帰関数設計

## 現状の問題

現在、XS言語では再帰関数の定義に `rec` キーワードが必要：

```lisp
(rec factorial (n: Int)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
```

これは以下の問題を引き起こしている：
- ユーザーが `let` と `rec` を使い分ける必要がある
- エラーメッセージが不親切（「Undefined variable: repeatString」）
- 他の現代的な言語（Python、JavaScript等）では不要

## 提案：自動再帰検出

### アプローチ1: 同値再帰（Equi-recursive）
- 型チェック時に再帰を自動的に検出
- `let` で定義された関数が自分自身を参照していれば再帰として扱う
- 実装が簡単で、ユーザーフレンドリー

### アプローチ2: 同型再帰（Iso-recursive）
- 明示的な fold/unfold が必要
- より厳密な型理論的アプローチ
- 実装が複雑で、ユーザーにとっても複雑

## 推奨：同値再帰アプローチ

### 利点
1. **シンプルな構文**：
   ```lisp
   (let factorial (n: Int)
     (if (= n 0)
         1
         (* n (factorial (- n 1)))))
   ```

2. **自然な記述**：Python や JavaScript のような感覚で書ける

3. **後方互換性**：既存の `rec` も残せる（非推奨として）

### 実装方針

1. **パーサー段階**：
   - `let` と `rec` を同じように扱う
   - ASTに `is_recursive` フラグを追加

2. **型チェック段階**：
   - 関数本体で自己参照を検出
   - 検出された場合、再帰的な型環境を構築

3. **評価段階**：
   - `is_recursive` フラグに基づいて `RecClosure` または通常の `Closure` を生成

### 再帰検出アルゴリズム

```rust
fn detect_recursion(name: &Ident, body: &Expr) -> bool {
    match body {
        Expr::Ident(id, _) => id == name,
        Expr::Apply { func, args, .. } => {
            detect_recursion(name, func) || 
            args.iter().any(|arg| detect_recursion(name, arg))
        }
        Expr::If { cond, then_expr, else_expr, .. } => {
            detect_recursion(name, cond) ||
            detect_recursion(name, then_expr) ||
            detect_recursion(name, else_expr)
        }
        // ... 他の式も同様に処理
        _ => false,
    }
}
```

## 移行計画

1. **Phase 1**: `let` で再帰を自動検出（`rec` は引き続きサポート）
2. **Phase 2**: `rec` を非推奨に
3. **Phase 3**: `rec` を削除（オプション）

## 相互再帰の扱い

相互再帰は `letRec` で明示的に：

```lisp
(letRec even (n: Int) (if (= n 0) true (odd (- n 1))))
(letRec odd (n: Int) (if (= n 0) false (even (- n 1))))
```

または、グループ化された `let` で：

```lisp
(let-group
  ((even (n: Int) (if (= n 0) true (odd (- n 1))))
   (odd (n: Int) (if (= n 0) false (even (- n 1))))))
```

## 結論

同値再帰アプローチを採用し、`let` で自動的に再帰を検出することで：
- より直感的な言語設計
- 初心者にやさしい
- 現代的な言語との一貫性

これにより、XS言語はAIにとって理解しやすく、人間にとっても書きやすい言語になる。
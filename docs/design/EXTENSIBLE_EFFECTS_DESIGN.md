# Extensible Effects 設計ドキュメント

## 概要
XS言語にExtensible Effectsシステムを実装し、効果の自動推論と合成可能な効果ハンドラーを提供します。

## 設計目標
1. **効果の自動推論**: 明示的な効果アノテーションなしで効果を推論
2. **効果の合成**: 複数の効果を柔軟に組み合わせ
3. **効果ハンドラー**: 効果を処理するハンドラーの定義
4. **型安全性**: 効果の型安全な取り扱い

## 効果推論アルゴリズム

### 基本的な推論規則

```
Γ ⊢ e : τ ! ε
```

- `Γ`: 型環境
- `e`: 式
- `τ`: 型
- `ε`: 効果の集合（effect row）

### 推論規則

1. **リテラル**
   ```
   Γ ⊢ lit : τ ! {}
   ```
   リテラルは純粋（効果なし）

2. **変数**
   ```
   x : τ ∈ Γ
   ─────────────
   Γ ⊢ x : τ ! {}
   ```

3. **関数適用**
   ```
   Γ ⊢ e1 : (τ1 → τ2 ! ε1) ! ε2
   Γ ⊢ e2 : τ1 ! ε3
   ─────────────────────────────
   Γ ⊢ (e1 e2) : τ2 ! (ε1 ∪ ε2 ∪ ε3)
   ```

4. **ラムダ抽象**
   ```
   Γ, x : τ1 ⊢ e : τ2 ! ε
   ─────────────────────────────
   Γ ⊢ (λx. e) : (τ1 → τ2 ! ε) ! {}
   ```

5. **Let束縛**
   ```
   Γ ⊢ e1 : τ1 ! ε1
   Γ, x : Gen(Γ, τ1, ε1) ⊢ e2 : τ2 ! ε2
   ──────────────────────────────────────
   Γ ⊢ (let x = e1 in e2) : τ2 ! (ε1 ∪ ε2)
   ```

6. **ビルトイン関数**
   ```
   print : String → Unit ! {IO}
   read : Unit → String ! {IO}
   ref : a → Ref a ! {State}
   get : Ref a → a ! {State}
   set : Ref a → a → Unit ! {State}
   ```

## Extensible Effects

### Row Polymorphism
効果変数を使用して、効果の集合を拡張可能にします：

```
(-> Int Int ! {IO | ρ})
```

ここで `ρ` は効果変数で、追加の効果を含むことができます。

### 効果ハンドラー

```lisp
(handler
  [(IO (print s) k) (begin (display s) (k unit))]
  [(IO (read) k) (k (input))]
  expr)
```

### 効果の合成

```lisp
; 複数の効果を持つ関数
(let process-file : (-> String Unit ! {IO, Error})
  (lambda (filename)
    (let contents (read-file filename))  ; IO効果
    (if (empty? contents)
      (error "Empty file")               ; Error効果
      (print contents))))                ; IO効果
```

## 実装計画

### Phase 1: 効果推論の基礎
1. 効果制約の収集
2. 効果の単一化アルゴリズム
3. 効果変数の一般化

### Phase 2: Row Polymorphism
1. 効果変数の導入
2. 効果のサブタイピング
3. 効果の合成演算

### Phase 3: 効果ハンドラー
1. ハンドラー構文の追加
2. 効果の削除と変換
3. 継続の取り扱い

### Phase 4: 最適化
1. 効果の静的解決
2. ハンドラーのインライン化
3. 効果のモノモーフィゼーション

## 型チェッカーの拡張

### EffectConstraint
```rust
pub enum EffectConstraint {
    // ε1 = ε2
    Equal(EffectRow, EffectRow),
    // ε1 ⊆ ε2
    Subset(EffectRow, EffectRow),
    // ε = ε1 ∪ ε2
    Union(EffectRow, EffectRow, EffectRow),
}
```

### EffectInference
```rust
pub struct EffectInference {
    constraints: Vec<EffectConstraint>,
    substitution: HashMap<EffectVar, EffectRow>,
}
```

## 例

### 基本的な効果推論
```lisp
; 推論: (-> String Unit ! {IO})
(let greet (lambda (name)
  (print (concat "Hello, " name))))

; 推論: (-> Int Int ! {})
(let double (lambda (x) (* x 2)))

; 推論: (-> String Int ! {IO, Error})
(let count-lines (lambda (filename)
  (let contents (read-file filename))  ; IO
  (if (null? contents)
    (error "File not found")           ; Error
    (length (split contents "\n")))))  ; Pure
```

### 効果ハンドラーの使用
```lisp
; IOハンドラー
(handler
  [(IO (print s) k) 
   (begin 
     (vector-push! output-buffer s)
     (k unit))]
  [(IO (read) k)
   (k (vector-pop! input-buffer))]
  ; 本体
  (begin
    (print "Enter name: ")
    (let name (read))
    (print (concat "Hello, " name))))

; Stateハンドラー
(handler
  [(State (get) k) (k current-state)]
  [(State (set v) k) 
   (begin
     (set! current-state v)
     (k unit))]
  ; 本体
  (begin
    (set 0)
    (set (+ (get) 1))
    (get)))  ; => 1
```

## テスト戦略

1. **単純な効果推論**: リテラル、変数、関数適用
2. **効果の合成**: 複数の効果を持つ関数
3. **効果の一般化**: Let多相での効果
4. **Row Polymorphism**: 効果変数の取り扱い
5. **効果ハンドラー**: ハンドラーによる効果の削除
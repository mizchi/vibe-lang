# XS言語 Effect System設計書

## 概要
XS言語のEffect Systemは、AI向けの静的解析を重視し、副作用を型レベルで追跡・管理することを目的とする。

## 設計方針

### 1. AI向け静的解析の最適化
- **完全な副作用追跡**: すべての副作用を型レベルで表現
- **解析可能性**: AIが容易に副作用を理解・推論できる設計
- **明示的な効果宣言**: 暗黙的な副作用を排除

### 2. 効果の種類
```
Effect = 
  | Pure                    -- 純粋（副作用なし）
  | IO                      -- 入出力
  | State<T>                -- 状態変更
  | Error<E>                -- エラー発生の可能性
  | Async                   -- 非同期処理
  | Network                 -- ネットワークアクセス
  | FileSystem              -- ファイルシステムアクセス
  | Random                  -- 乱数生成
  | Time                    -- 時刻取得
  | Log                     -- ログ出力
```

### 3. 効果の合成
複数の効果を持つ関数の型表現：
```
; 単一効果
(-> Int Int ! IO)           ; IOを伴う関数

; 複数効果
(-> String String ! {IO, Error<String>})  ; IOとエラーの可能性

; 効果多相
(-> (a ! e) (b ! e) (List a) (List b) ! e)  ; 効果を保存するmap
```

### 4. 効果ハンドラー
効果を処理するハンドラー構文：
```lisp
(handle expr
  (Pure x) -> x
  (Error e) -> (default-value)
  (IO action) -> (perform-io action))
```

## 実装計画

### Phase 1: 基本的な効果システム（2時間）
- [ ] Effect型の定義（xs_core）
- [ ] 効果付き関数型の拡張
- [ ] Pure効果とIO効果の実装

### Phase 2: 型推論の拡張（2時間）
- [ ] 効果推論アルゴリズム
- [ ] 効果の単一化（unification）
- [ ] 効果多相の実装

### Phase 3: 効果ハンドラー（1時間）
- [ ] handle構文のパーサー
- [ ] 効果ハンドラーの型チェック
- [ ] ランタイム実装

### Phase 4: 標準効果ライブラリ（1時間）
- [ ] 各種効果の実装
- [ ] 効果の合成演算子
- [ ] テストとドキュメント

## 型システムへの統合

### 1. Type定義の拡張
```rust
pub enum Type {
    // ... 既存の型 ...
    Effect(Box<Type>, EffectSet),  // T ! {effects}
}

pub struct EffectSet {
    effects: BTreeSet<Effect>,
}

pub enum Effect {
    Pure,
    IO,
    State(Box<Type>),
    Error(Box<Type>),
    Async,
    Network,
    FileSystem,
    Random,
    Time,
    Log,
}
```

### 2. 関数型の拡張
関数型に効果情報を追加：
```rust
Type::Function {
    from: Box<Type>,
    to: Box<Type>,
    effects: EffectSet,
}
```

## AIフレンドリーな設計

### 1. 効果の推論可能性
- すべての関数の効果が静的に決定可能
- 効果の伝播が予測可能
- 効果の包含関係が明確

### 2. 効果の可視化
```lisp
; 効果情報を含む型シグネチャ
add : (-> Int Int Int ! Pure)
readFile : (-> String String ! {IO, Error<IOError>})
httpGet : (-> String String ! {Network, Async, Error<NetworkError>})
```

### 3. 効果解析API
```rust
// 関数の効果を取得
fn get_effects(expr: &Expr) -> EffectSet;

// 式全体の効果を計算
fn compute_effects(expr: &Expr) -> EffectSet;

// 効果の依存グラフを生成
fn effect_dependency_graph(module: &Module) -> Graph;
```

## 使用例

### 1. 純粋な関数
```lisp
(let double (lambda (x) (* x 2)))  ; (-> Int Int ! Pure)
```

### 2. IO効果を持つ関数
```lisp
(let print-number (lambda (x) 
  (print (int-to-string x))))  ; (-> Int Unit ! IO)
```

### 3. エラー処理
```lisp
(let safe-div (lambda (x y)
  (if (== y 0)
      (error "Division by zero")
      (/ x y))))  ; (-> Int Int Int ! Error<String>)
```

### 4. 効果の合成
```lisp
(let read-and-parse (lambda (filename)
  (let contents (read-file filename))    ; ! {IO, Error}
  (parse-json contents)))                 ; ! Error
; 全体: (-> String Json ! {IO, Error})
```

### 5. 効果ハンドラー
```lisp
(let safe-read (lambda (filename)
  (handle (read-file filename)
    (Pure content) -> (Some content)
    (Error _) -> None)))
; (-> String (Option String) ! Pure)
```

## 今後の拡張可能性

1. **リージョンベース効果**: メモリ安全性の保証
2. **線形効果**: リソース管理の静的保証
3. **効果の細分化**: より詳細な効果追跡
4. **カスタム効果**: ユーザー定義効果のサポート
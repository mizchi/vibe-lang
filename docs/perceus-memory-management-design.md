# Perceus メモリ管理システム設計書

## 1. Perceusの概要

Perceus (Precise Reference Counting with Reuse and Specialization) は、関数型プログラミング言語向けの革新的なメモリ管理手法です。Microsoft Research によって開発され、Koka言語で実装されています。

### 主な特徴

1. **ガベージフリー**: サイクルのないプログラムでは、オブジェクトは参照されなくなった瞬間に即座に解放される
2. **決定論的動作**: 通常のmalloc/freeと同様の予測可能な動作
3. **再利用最適化**: in-place更新による効率的なメモリ利用
4. **FBIP (Functional But In-Place)**: 純粋関数型スタイルでin-place更新アルゴリズムを記述可能

## 2. 従来の参照カウントとの違い

### 従来の参照カウント
- オブジェクトごとにカウンタを保持
- 参照の追加/削除時にカウンタを増減
- カウンタが0になった時点で解放
- 循環参照の問題がある

### Perceus
- **線形リソース計算**に基づく
- コンパイル時の静的解析により最適化
- drop/dup命令の精密な配置
- 再利用分析によるin-place更新

## 3. 線形リソース計算とdrop/dup操作

### 線形論理の原則
- 各リソースは**正確に一度**使用される
- 複製（dup）と破棄（drop）は明示的に管理

### drop/dup命令
```
drop x    -- リソースxを破棄（参照カウント-1）
dup x     -- リソースxを複製（参照カウント+1）
```

### 命令挿入アルゴリズム
1. **活性解析**: 各プログラム点で生きている変数を特定
2. **線形性チェック**: 各変数が正確に一度使用されることを保証
3. **drop挿入**: 変数が最後に使用された後にdropを挿入
4. **dup挿入**: 変数が複数回使用される場合、使用前にdupを挿入

## 4. 再利用分析とin-place更新

### 再利用の条件
1. オブジェクトの参照カウントが1（unique reference）
2. 型が一致する
3. メモリレイアウトが互換

### 実装例
```lisp
; 従来: 新しいリストを作成
(let old-list (list 1 2 3))
(let new-list (cons 0 old-list))  ; old-listをコピー

; Perceus: in-place更新
(let list (list 1 2 3))
(let list' (cons 0 list))  ; listが唯一参照なら再利用
```

## 5. XS言語への実装設計

### 5.1 型システムの拡張

```rust
// core/src/types.rs に追加
#[derive(Debug, Clone, PartialEq)]
pub enum Ownership {
    Owned,      // 所有権を持つ（参照カウント1）
    Borrowed,   // 借用（参照カウントは増やさない）
    Shared,     // 共有（参照カウント > 1）
}

#[derive(Debug, Clone)]
pub struct TypeWithOwnership {
    pub ty: Type,
    pub ownership: Ownership,
}
```

### 5.2 中間表現（IR）の設計

```rust
// core/src/ir.rs
#[derive(Debug, Clone)]
pub enum IrExpr {
    // 既存の式...
    Drop(String),           // drop命令
    Dup(String),            // dup命令
    ReuseCheck(String),     // 再利用可能性チェック
}
```

### 5.3 Perceus変換パス

```rust
// checker/src/perceus.rs
pub struct PerceusTransform {
    // 活性変数の追跡
    live_vars: HashSet<String>,
    // 使用回数の追跡
    use_counts: HashMap<String, usize>,
}

impl PerceusTransform {
    pub fn transform(&mut self, expr: TypedExpr) -> IrExpr {
        match expr {
            TypedExpr::Let(name, value, body) => {
                // 1. valueを変換
                let ir_value = self.transform(*value);
                
                // 2. use_countを計算
                let use_count = self.count_uses(&name, &body);
                
                // 3. bodyを変換
                let ir_body = self.transform(*body);
                
                // 4. drop/dup命令を挿入
                if use_count == 0 {
                    // 未使用：即座にdrop
                    IrExpr::Sequence(vec![
                        ir_value,
                        IrExpr::Drop(name.clone()),
                        ir_body,
                    ])
                } else if use_count > 1 {
                    // 複数回使用：dupを挿入
                    self.insert_dups(name, ir_body, use_count)
                } else {
                    // 一度だけ使用：最適
                    IrExpr::Let(name, Box::new(ir_value), Box::new(ir_body))
                }
            }
            // 他のケース...
        }
    }
}
```

### 5.4 再利用分析

```rust
// checker/src/reuse_analysis.rs
pub struct ReuseAnalyzer {
    // 各変数の所有権状態
    ownership_map: HashMap<String, Ownership>,
}

impl ReuseAnalyzer {
    pub fn analyze_constructor(&mut self, 
        constructor: &str, 
        args: &[String]
    ) -> Option<String> {
        // コンストラクタが既存のオブジェクトを再利用できるか分析
        for arg in args {
            if let Some(Ownership::Owned) = self.ownership_map.get(arg) {
                // 同じ型で所有権を持つ引数があれば再利用候補
                return Some(arg.clone());
            }
        }
        None
    }
}
```

## 6. WebAssembly GCとの統合

### 6.1 WasmGCの型システムとの対応

```wat
;; Perceus管理されたオブジェクト
(type $perceus_object (struct
  (field $ref_count i32)    ;; 参照カウント
  (field $data (ref any))   ;; 実際のデータ
))

;; drop関数
(func $drop (param $obj (ref $perceus_object))
  ;; 参照カウントをデクリメント
  (local.get $obj)
  (struct.get $perceus_object $ref_count)
  (i32.const 1)
  (i32.sub)
  (local.set $new_count)
  
  ;; 0になったら解放
  (if (i32.eqz (local.get $new_count))
    (then
      ;; WasmGCが自動的に回収
      (drop (local.get $obj))
    )
    (else
      ;; 参照カウントを更新
      (struct.set $perceus_object $ref_count
        (local.get $obj)
        (local.get $new_count)
      )
    )
  )
)
```

### 6.2 最適化戦略

1. **ローカル変数の最適化**: スタック上の値は参照カウント不要
2. **エスケープ解析**: 関数外に出ない値は参照カウント省略
3. **インライン化**: 小さな関数はインライン化して参照カウントを削減

## 7. 実装ロードマップ

### Phase 1: 基本実装（2週間）
- [ ] IR層の追加
- [ ] 基本的なdrop/dup挿入
- [ ] 単純な参照カウント実装

### Phase 2: 最適化（3週間）
- [ ] 活性解析の実装
- [ ] 再利用分析
- [ ] 借用推論

### Phase 3: WasmGC統合（2週間）
- [ ] WasmGCコード生成
- [ ] 最適化パス
- [ ] ベンチマーク

### Phase 4: 高度な機能（3週間）
- [ ] FBIP パターンのサポート
- [ ] 並行処理対応
- [ ] デバッグ機能

## 8. ベンチマークと評価

### 測定項目
1. **メモリ使用量**: 従来のGCとの比較
2. **レイテンシ**: GCポーズの削減
3. **スループット**: 全体的なパフォーマンス

### テストケース
- リスト処理
- ツリー操作
- 関数型データ構造の更新
- 大規模データ処理

## 9. 参考文献

1. "Perceus: Garbage Free Reference Counting with Reuse" - Reinking et al., PLDI 2021
2. Koka Language Documentation - https://koka-lang.github.io/
3. Linear Logic and Resource Management - Stanford Encyclopedia of Philosophy
4. WebAssembly GC Proposal - https://github.com/WebAssembly/gc

## 10. まとめ

Perceusは、関数型プログラミングの表現力とシステムプログラミングの効率性を両立させる革新的なメモリ管理手法です。XS言語への実装により、AI向けの高速な静的解析と効率的な実行を実現できます。

特にWebAssembly GCとの組み合わせにより、ブラウザ環境でも予測可能で高性能なメモリ管理が可能になります。これにより、XS言語はAI処理に適した次世代の言語として位置づけられます。
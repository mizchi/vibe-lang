# XS言語 WebAssembly GCバックエンド設計書

## 概要

本文書は、XS言語のWebAssembly GCバックエンドの設計について記述します。MoonBit言語の成功事例とWebAssembly GCの機能を参考に、Rustライクなパフォーマンス特性と小さな出力サイズを実現する設計を目指します。

## 設計目標

1. **Rustライクなパフォーマンス特性**
   - ゼロコスト抽象化の実現
   - 予測可能なメモリ使用
   - 効率的なデータレイアウト

2. **小さな出力サイズ**
   - デッドコード除去の最大化
   - 効率的な型表現
   - 最小限のランタイムオーバーヘッド

3. **WebAssembly GC機能の効率的な利用**
   - struct/array型の活用
   - i31ref型による小整数の最適化
   - ホストGCとの統合

4. **Perceusメモリ管理との統合**
   - 参照カウントとGCのハイブリッド戦略
   - FBIPパラダイムのサポート

## WebAssembly GC型システムのマッピング

### 基本型マッピング

```
XS型 → WebAssembly GC型
---
Int32      → i32 (値型として直接使用)
Int64      → i64 (値型として直接使用)
Float32    → f32 (値型として直接使用)
Float64    → f64 (値型として直接使用)
Bool       → i32 (0 = false, 1 = true)
SmallInt   → (ref i31) (31ビット整数の効率的表現)
String     → (ref array i8) (UTF-8エンコード)
```

### 複合型マッピング

```
# タプル型
(T1, T2, ..., Tn) → (ref struct (field T1) (field T2) ... (field Tn))

# レコード型
{ field1: T1, field2: T2 } → (ref struct (field $field1 T1) (field $field2 T2))

# 配列型
Array<T> → (ref array T)

# 関数型
(T1, T2) -> T3 → (ref func (param T1 T2) (result T3))

# バリアント型（代数的データ型）
type Option<T> = Some(T) | None
→ (ref struct (field $tag i32) (field $payload (ref any)))
  ここで $tag はバリアントのタグ値
```

## メモリ管理戦略

### 1. ハイブリッドアプローチ

- **即値型**: スタック上で管理（i32, i64, f32, f64）
- **小整数**: i31refを使用してヒープ割り当てを回避
- **参照型**: WebAssembly GCで管理
- **線形型**: Perceusスタイルの参照カウントで管理

### 2. i31ref最適化

小さな整数値（-2^30 から 2^30-1）は、i31ref型を使用してボックス化を回避：

```wasm
;; 小整数の作成
(ref.i31 (i32.const 42))

;; 小整数の取得
(i31.get_s (local.get $small_int))
```

### 3. 文字列の最適化

- 短い文字列（31バイト以下）: インライン表現を検討
- 長い文字列: (ref array i8)として表現
- 文字列リテラル: グローバル定数として共有

## コード生成最適化

### 1. インライン化戦略

MoonBitのアプローチを参考に、以下を実装：

- **小関数の自動インライン化**: 単純な関数は呼び出しオーバーヘッドを除去
- **ジェネリクスの単相化**: 使用される型ごとに特殊化されたコードを生成
- **定数畳み込み**: コンパイル時に計算可能な式を事前評価

### 2. デッドコード除去

```
1. 全プログラム解析による未使用関数の検出
2. 型駆動の到達可能性解析
3. バリアントの未使用ケースの除去
4. 未使用フィールドの除去（構造体の最適化）
```

### 3. メモリレイアウト最適化

```wasm
;; 効率的な構造体レイアウト
(type $point (struct
  (field $x f64)  ;; 8バイトアライメント
  (field $y f64)  ;; 連続配置
  (field $tag i32) ;; パディングを最小化
))
```

## Perceusとの統合

### 1. 参照カウント命令の生成

```wasm
;; 参照カウントのインクリメント
(func $rc_inc (param $ref (ref any))
  ;; Perceus最適化: borrowチェック
  (if (call $is_unique (local.get $ref))
    (then
      ;; ユニーク参照の場合は何もしない
    )
    (else
      ;; 共有参照の場合はカウントを増やす
      (call $increment_rc (local.get $ref))
    )
  )
)

;; 参照カウントのデクリメント
(func $rc_dec (param $ref (ref any))
  (call $decrement_rc (local.get $ref))
  ;; カウントが0になった場合、GCが自動的に回収
)
```

### 2. FBIP（Functional But In-Place）最適化

パターンマッチングでの再利用：

```wasm
;; リストの先頭要素を更新（in-place）
(func $update_head (param $list (ref $cons)) (param $new_val i32) (result (ref $cons))
  ;; ユニーク参照チェック
  (if (result (ref $cons)) (call $is_unique (local.get $list))
    (then
      ;; in-place更新
      (struct.set $cons $head (local.get $list) (local.get $new_val))
      (local.get $list)
    )
    (else
      ;; 新しいコンスセルを作成
      (struct.new $cons
        (local.get $new_val)
        (struct.get $cons $tail (local.get $list))
      )
    )
  )
)
```

## パフォーマンス目標と測定

### 1. ベンチマーク項目

- **起動時間**: WebAssemblyモジュールのインスタンス化時間
- **実行速度**: 数値計算、文字列処理、データ構造操作
- **メモリ使用量**: ヒープ使用量とGC頻度
- **コードサイズ**: 生成されるWASMファイルのサイズ

### 2. 目標値

- **コードサイズ**: MoonBit同等（"Hello World"で数KB以下）
- **実行速度**: ネイティブJavaScriptの5-10倍
- **メモリ効率**: Perceus最適化により40%以上の削減

## 実装フェーズ

### フェーズ1: 基本型システム
- WebAssembly GC型へのマッピング実装
- 基本的なstruct/array型の生成
- i31ref最適化の実装

### フェーズ2: メモリ管理
- Perceus参照カウントの基本実装
- GCとの統合
- 基本的なFBIP最適化

### フェーズ3: 最適化
- インライン化とデッドコード除去
- 全プログラム最適化
- メモリレイアウト最適化

### フェーズ4: パフォーマンスチューニング
- ベンチマークの実装と測定
- ボトルネックの特定と改善
- 最終的な最適化

## 技術的課題と対策

### 1. 型システムの制約
- **課題**: WebAssembly GCの型システムは比較的制限的
- **対策**: 効率的な型エンコーディングとランタイム型情報の最小化

### 2. GCとPerceusの統合
- **課題**: 2つの異なるメモリ管理戦略の共存
- **対策**: 明確な責任分離と相互運用プロトコル

### 3. デバッグ情報
- **課題**: 最適化されたコードのデバッグ
- **対策**: ソースマップの生成とデバッグモードの提供

## まとめ

本設計により、XS言語は以下を実現します：

1. **高速な実行**: WebAssembly GCの効率的な利用とPerceus最適化
2. **小さなコードサイズ**: 積極的なデッドコード除去と最適化
3. **予測可能なパフォーマンス**: 決定的なメモリ管理
4. **AI向け設計**: 高速な静的解析と明確な型情報

この設計は、MoonBitの成功事例を参考にしつつ、XS言語独自の要件（AI向け静的解析）に最適化されています。
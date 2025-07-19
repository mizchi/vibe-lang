# XS Language - AI-Oriented Programming Language

XS Language is an AI-oriented programming language designed for fast static analysis with S-expression syntax. It features a static type system with Hindley-Milner type inference, incremental compilation using Salsa framework, Perceus memory management, and WebAssembly backend with GC support.

## 特徴

- **S式構文**: パース効率を最大化し、AIによる解析を容易に
- **静的型付き**: HM型推論による型安全性の保証
- **インクリメンタルコンパイル**: Salsaフレームワークによる高速な差分コンパイル
- **Perceus GC**: 参照カウントベースの効率的なメモリ管理
- **WebAssemblyバックエンド**: モダンなWebAssembly GCランタイムへのコンパイル

## クイックスタート

```bash
# ビルド
cargo build --release

# プログラムの実行
cargo run --bin xsc -- run examples/arithmetic.xs

# 型チェック
cargo run --bin xsc -- check examples/lambda.xs

# AST表示
cargo run --bin xsc -- parse examples/list.xs
```

## 言語仕様

### 基本構文

```lisp
; 変数定義
(let x 42)
(let name "Alice")

; 関数定義
(let double (lambda (x) (* x 2)))

; 型アノテーション
(let x : Int 42)
(let f : (-> Int Int) (lambda (x) (+ x 1)))

; 条件分岐
(if (< x 10) 
    "small" 
    "large")

; リスト操作
(let nums (list 1 2 3 4 5))
(cons 0 nums)

; 関数適用
(double 21)  ; => 42
```

### 型システム

- **基本型**: `Int`, `Bool`, `String`
- **複合型**: `List a`, `(-> a b)`
- **型変数**: `a`, `b`, `c`...
- **Let多相**: 関数の汎用的な型定義が可能

## プロジェクト構造

```
xs-lang-v3/
├── xs_core/        # 共通型定義とIR
├── parser/         # S式パーサー
├── checker/        # HM型推論エンジン
├── interpreter/    # インタープリター
├── cli/            # コマンドラインインターフェース
├── xs_salsa/       # インクリメンタルコンパイル
├── perceus/        # Perceus GC変換
└── wasm_gc/        # WebAssembly GCコード生成
```

## アーキテクチャ

### コンパイルパイプライン

```
ソースコード (S式)
    ↓ [Parser]
AST (抽象構文木)
    ↓ [Type Checker]
型付きAST
    ↓ [Perceus Transform]
IR (中間表現 + drop/dup)
    ↓ [WebAssembly GC CodeGen]
WebAssembly モジュール
```

### インクリメンタルコンパイル

Salsaフレームワークを使用して、変更された部分のみを再コンパイルすることで高速な開発サイクルを実現:

```rust
// ファイルが変更されても、影響を受けない部分はキャッシュから読み込まれる
compiler.set_source_text(path, new_content);
let result = compiler.type_check_program(path); // 差分のみ再計算
```

### Perceus メモリ管理

参照カウントベースの自動メモリ管理で、ガベージコレクションのオーバーヘッドを削減:

```lisp
(let x (list 1 2 3))    ; x は所有権を持つ
(let y x)               ; 所有権がyに移動
; xはここで自動的にdrop
```

## 開発状況

### 実装済み機能

- ✅ S式パーサー
- ✅ HM型推論
- ✅ 基本的なインタープリター
- ✅ CLIツール
- ✅ Salsaインクリメンタルコンパイル
- ✅ Perceus IR変換
- ✅ WebAssembly GC基本実装

### 今後の実装予定

- 🚧 let-rec完全サポート
- 📋 パターンマッチング
- 📋 モジュールシステム
- 📋 最適化パス
- 📋 デバッガー統合

## サンプルプログラム

### フィボナッチ数列

```lisp
(let-rec fib (lambda (n)
    (if (< n 2)
        n
        (+ (fib (- n 1)) (fib (- n 2)))))
(fib 10))
```

### 高階関数

```lisp
(let map (lambda (f lst)
    (if (null? lst)
        '()
        (cons (f (car lst)) 
              (map f (cdr lst))))))

(let double (lambda (x) (* x 2)))
(map double (list 1 2 3 4 5))
```

## テスト

```bash
# 単体テスト
cargo test

# 統合テスト
cargo test --test integration_test

# ベンチマーク
cargo bench
```

## ライセンス

MIT License

## 貢献

プルリクエストを歓迎します。大きな変更を行う場合は、まずイシューを作成して変更内容について議論してください。
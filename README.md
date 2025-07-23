# XS Language - AI-Oriented Programming Language

XS Language is an AI-oriented programming language designed for fast static analysis with S-expression syntax. It features a static type system with Hindley-Milner type inference, incremental compilation using Salsa framework, Perceus memory management, WebAssembly backend with GC support, and Unison-style content-addressed code storage.

## 特徴

- **Haskell風構文**: ブロックスコープとパイプライン演算子をサポートした読みやすい構文
- **静的型付き**: HM型推論による型安全性の保証
- **インクリメンタルコンパイル**: Salsaフレームワークによる高速な差分コンパイル
- **Perceus GC**: 参照カウントベースの効率的なメモリ管理
- **WebAssemblyバックエンド**: モダンなWebAssembly GCランタイムへのコンパイル
- **構造化コードベース**: Unison風のコンテンツアドレス型ストレージ
- **統一ランタイム**: インタープリターとWebAssemblyの統一されたバックエンドインターフェース
- **名前空間システム**: 階層的な名前空間と依存関係管理
- **ASTコマンド**: 構造的なコード変換のためのコマンドシステム
- **差分テスト実行**: 変更の影響を受けるテストのみを実行

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

```haskell
-- 変数定義
let x = 42
let name = "Alice"

-- 関数定義
let double = fn x -> x * 2

-- 型アノテーション
let x : Int = 42
let f : Int -> Int = fn x -> x + 1

-- 条件分岐
if x < 10 { "small" } else { "large" }

-- リスト操作
let nums = [1, 2, 3, 4, 5]
cons 0 nums

-- 関数適用
double 21  -- => 42
```

### 再帰関数

```haskell
-- rec構文（型推論サポート）
rec factorial n =
    if (eq n 0) {
        1
    } else {
        n * (factorial (n - 1))
    }

-- letRec構文（ハイフンなしのlowerCamelCase）
letRec fib n =
    if n < 2 {
        n
    } else {
        (fib (n - 1)) + (fib (n - 2))
    }
```

### 代数的データ型とパターンマッチ

```haskell
-- 型定義
type Option a =
  | None
  | Some a

-- パターンマッチ
match opt {
  None -> 0
  Some x -> x
}
```

### 型システム

- **基本型**: `Int`, `Float`, `Bool`, `String`
- **複合型**: `List a`, `(-> a b)`
- **型変数**: `a`, `b`, `c`...
- **Let多相**: 関数の汎用的な型定義が可能
- **代数的データ型**: ユーザー定義型とコンストラクタ

## プロジェクト構造

```
xs-lang-v3/
├── xs-core/        # 言語コア（AST定義、型定義、パーサー、プリティプリンタ）
├── xs-compiler/    # コンパイラ（型チェッカー、メモリ最適化）
├── xs-runtime/     # ランタイム（インタープリター、評価器）
├── xs-wasm/        # WebAssemblyバックエンド（WASMコード生成、WASIサンドボックス）
├── xs-workspace/   # ワークスペース管理（コードベース、インクリメンタルコンパイル）
├── xs-tools/       # CLIツール（xscコマンド、REPL、コンポーネントコマンド）
├── xs-test/        # テストフレームワーク
└── benches/        # パフォーマンスベンチマーク
```

## アーキテクチャ

### コンパイルパイプライン

```
ソースコード (Haskell風構文)
    ↓ [Parser]
AST (抽象構文木)
    ↓ [Type Checker]
型付きAST
    ↓ [Perceus Transform]
TypedIR (型付き中間表現)
    ↓ [Backend (Interpreter/WebAssembly)]
実行結果
```

### 統一ランタイムアーキテクチャ

```rust
// バックエンドトレイト
trait Backend {
    type Output;
    fn compile(&mut self, ir: &TypedIrExpr) -> Result<Self::Output, Self::Error>;
    fn execute(&mut self, compiled: &Self::Output) -> Result<Value, RuntimeError>;
}

// 使用例
let mut runtime = Runtime::new(InterpreterBackend::new());
let result = runtime.eval(&typed_ir)?;
```

### Unison風構造化コードベース

コンテンツアドレス型ストレージにより、関数単位での依存関係管理が可能：

```rust
// 関数をハッシュで管理
let hash = codebase.add_term(Some("factorial"), expr, ty)?;

// UCM風のedit機能
let expanded_code = codebase.edit("factorial")?;

// パッチによるインクリメンタル更新
let mut patch = Patch::new();
patch.update_term("factorial", new_code);
patch.apply(&mut codebase)?;
```

### 名前空間システム

階層的な名前空間で整理されたコードベース：

```lisp
; 名前空間の定義
(namespace Math.Utils
  (export fibonacci square))

; 完全修飾名でのアクセス
(Math.Utils.fibonacci 10)

; インポート
(import Math.Utils (fibonacci square))
(fibonacci 10)  ; 直接呼び出し可能
```

### ASTコマンドシステム

構造的で型安全なコード変換：

```rust
// 変数名の変更
let cmd = AstCommand::Rename {
    scope: AstPath::root(),
    old_name: "oldVar".to_string(),
    new_name: "newVar".to_string(),
};

// 式の抽出
let cmd = AstCommand::Extract {
    target: path_to_expr,
    definition_name: "helper".to_string(),
    namespace: NamespacePath::current(),
};
```

### インクリメンタルコンパイル

Salsaフレームワークを使用して、変更された部分のみを再コンパイルすることで高速な開発サイクルを実現：

```rust
// ファイルが変更されても、影響を受けない部分はキャッシュから読み込まれる
db.set_source_text(path, new_content);
let result = db.type_check_program(path); // 差分のみ再計算
```

### Perceus メモリ管理

参照カウントベースの自動メモリ管理で、ガベージコレクションのオーバーヘッドを削減：

```lisp
(let x (list 1 2 3))    ; x は所有権を持つ
(let y x)               ; 所有権がyに移動
; xはここで自動的にdrop
```

## ビルトイン関数

### 算術演算
- `+`, `-`, `*`, `/` : 整数演算
- `+.`, `-.`, `*.`, `/.` : 浮動小数点演算

### 比較演算
- `<`, `>`, `<=`, `>=` : 大小比較
- `=` : 等価比較

### リスト操作
- `cons` : リストの先頭に要素を追加
- `list` : 可変長引数でリストを構築

## 開発状況

### 実装済み機能

- ✅ S式パーサー（lowerCamelCase対応）
- ✅ HM型推論（完全な型推論サポート）
- ✅ 基本的なインタープリター
- ✅ CLIツール
- ✅ Salsaインクリメンタルコンパイル
- ✅ Perceus IR変換
- ✅ WebAssembly GC基本実装
- ✅ rec/letRec構文（型推論対応）
- ✅ 代数的データ型
- ✅ パターンマッチング
- ✅ モジュールシステム（基本実装）
- ✅ 統一ランタイムインターフェース
- ✅ Unison風構造化コードベース
- ✅ 階層的な名前空間システム
- ✅ 関数単位の依存関係追跡
- ✅ ASTコマンドによる構造的変換
- ✅ インクリメンタル型チェック
- ✅ 差分テスト実行システム
- ✅ 包括的なテストカバレッジ（76.63%）

### 今後の実装予定

- 🚧 標準ライブラリの拡充
- 📋 最適化パス
- 📋 デバッガー統合
- 📋 LSP (Language Server Protocol) サポート
- 📋 パッケージマネージャー

## パフォーマンス

型チェッカーのパフォーマンスベンチマーク：

```bash
# ベンチマークの実行
cargo bench --bench type_checker_bench

# 主要なベンチマーク項目
- nested_let: ネストしたlet束縛のスケーリング
- nested_lambda: ネストしたラムダ式の型推論
- polymorphic_inference: ポリモーフィック関数の型推論
- incremental_checking: インクリメンタル型チェック
- type_instantiation: 型インスタンス化の性能
```

## サンプルプログラム

### フィボナッチ数列（rec構文）

```lisp
(rec fib (n)
    (if (< n 2)
        n
        (+ (fib (- n 1)) (fib (- n 2)))))

(fib 10)  ; => 55
```

### 高階関数とリスト操作

```lisp
(let map (fn (f lst)
    (match lst
        ((list) (list))
        ((cons x xs) (cons (f x) (map f xs)))))

(let double (fn (x) (* x 2)))
(map double (list 1 2 3 4 5))  ; => (list 2 4 6 8 10)
```

### 代数的データ型の例

```lisp
(type Tree a
    (Leaf a)
    (Node (Tree a) (Tree a)))

(rec sumTree (tree)
    (match tree
        ((Leaf n) n)
        ((Node left right) (+ (sumTree left) (sumTree right))))))

(sumTree (Node (Leaf 1) (Node (Leaf 2) (Leaf 3))))  ; => 6
```

## テスト

```bash
# 単体テスト
cargo test

# 統合テスト
cargo test --test integration_test

# カバレッジレポート生成
cargo llvm-cov --workspace --html

# ベンチマーク
cargo bench
```

### テストカバレッジ

現在のテストカバレッジ: **76.63%**

主要コンポーネントのカバレッジ:
- runtime/backend.rs: 97.64%
- xs_core/value.rs: 100%
- xs_core/ir.rs: 95.35%
- checker: 88.35%
- interpreter: 83.26%
- parser: 83.55%

## ライセンス

MIT License

## 貢献

プルリクエストを歓迎します。大きな変更を行う場合は、まずイシューを作成して変更内容について議論してください。

開発に参加する前に、`CLAUDE.md`を参照してプロジェクトの設計方針を理解してください。
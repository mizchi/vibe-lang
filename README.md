AOAI DevDay で、デモのためにライブコーディングして作った言語です。

発表中の裏で 40 分ぐらいで作った言語です。動作チェックはしてません

[初期プロンプト](./CLAUDE)

https://aoai-ai-coding.mizchi.workers.dev/

---

# XS Language

AI のための高速静的解析言語

## 概要

XS 言語は、AI が効率的に静的解析結果を取得できるように設計された S 式ベースの静的型付き言語です。HM 型推論により、型安全性を保ちながら簡潔な記述が可能です。

## 特徴

- **S 式構文**: パーサー実装の効率化と高速な構文解析
- **静的型付き**: 明示的な型アノテーションをサポート
- **HM 型推論**: 型の自動推論により記述効率を向上
- **関数型プログラミング**: ラムダ式、高階関数、let 多相をサポート

## インストール

```bash
git clone <repository-url>
cd xs-lang
cargo build --release
```

## 使い方

### プログラムの実行

```bash
./target/release/xsc run examples/hello.xs
```

### 型チェック

```bash
./target/release/xsc check examples/lambda.xs
```

### AST 表示

```bash
./target/release/xsc parse examples/list.xs
```

## 言語仕様

### 基本構文

```lisp
; リテラル
42              ; 整数
true            ; 真偽値
"Hello"         ; 文字列

; 変数定義
(let x 42)

; 型アノテーション付き変数定義
(let x : Int 42)

; ラムダ式
(lambda (x) (+ x 1))
(lambda (x : Int y : Int) (+ x y))

; 関数適用
(f x y)

; 条件分岐
(if (< x 10) "small" "large")

; リスト
(list 1 2 3)
(cons 1 (list 2 3))
```

### 型システム

- 基本型: `Int`, `Bool`, `String`
- リスト型: `(List a)`
- 関数型: `(-> a b)`
- 型変数: `a`, `b`, `c`...

### 組み込み関数

- 算術演算: `+`, `-`, `*`, `/`
- 比較演算: `<`, `>`, `=`
- リスト操作: `list`, `cons`

## プロジェクト構成

```
xs-lang/
├── xs_core/      # 共通の型定義とエラー型
├── parser/       # S式パーサー
├── checker/      # HM型推論と型チェッカー
├── interpreter/  # インタープリター
├── cli/          # コマンドラインインターフェース
└── examples/     # サンプルプログラム
```

## 開発

テストの実行:

```bash
cargo test
```

各 crate のテスト:

```bash
cargo test -p parser
cargo test -p checker
cargo test -p interpreter
cargo test -p cli
```

## ライセンス

MIT License

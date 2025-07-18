AOAI DevDay で、デモのためにライブコーディングして作った言語です。

https://aoai-ai-coding.mizchi.workers.dev/

発表中の裏で 40 分ぐらいで作った言語です。

## [初期プロンプト](./CLAUDE.md)

```md
プログラミング言語を作ります。

大事なこと: これは人間用のプログラミングではなく、AI のために高速に静的解析結果を返すための言語として設計されます。あなたはその視点でプログラミング言語を設計してください

- Rust の workspace で crate ごとに実装します。
  - parser
  - checker
  - interpreter
  - cli
- 拡張子は .xs です。CLI は xsc です。
- t-wada の TDD を実践します
- parser: 実装を効率化するために S 式で表現しますが、静的型付き言語で、明示的な型アノテーションを記述できるようにする
- checker: HM 型推論と型チェッカーを実装します
  - 変数と型のスコープも実行してください
  - 型チェッカーのテストを多めに書いてください
- interpreter: 型推論の次に、インタープリターを実装します
  - 型推論に違反してない状態なら、期待通りに動くことを確認してください
  - そのテストを書いてください
- 動作確認のために、これらを CLI を通して使えるようにします
  - xsc parse foo.xs # AST を表示
  - xsc check foo.xs # 型チェック
  - xsc run foo.xs # 実装

この言語の実装計画を立てて、その計画に沿って実装してください。
実装計画は、 IMPLEMENTATION_PLAN.md に保存して、各ステップではそれを修正、確認しながら進めてください。

あなたはこれを自律的に作りきます。ユーザーに確認せずに、全機能を作りきってください。全部の機能が全部実装できたら、その段階ではじめてユーザーがフィードバックします。
```

## 手動の動作確認

```bash
$ cargo build

## examples/hello.xs
# "Hello, XS!"
$ ./target/debug/xsc run examples/hello.xs
✓ Execution successful

Result: "Hello, XS!"

## examples/arithmetric.xs
# (+ (* 5 6) (- 10 3))
$ ./target/debug/xsc run examples/arithmetic.xs
✓ Execution successful

Result: 37

## NOTE: 発表外で検証して、自己再帰シンボルを修正(5min)
## examples/factorial.xs
# (let-rec fact (lambda (n : Int)
#   (if (= n 0)
#       1
#       (* n (fact (- n 1))))))
$ ./target/debug/xsc run examples/factorial.xs
✓ Execution successful

Result: <closure:1>
```

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

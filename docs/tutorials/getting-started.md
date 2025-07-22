# XS Language チュートリアル

## はじめに

XS言語は、AIによる理解と生成を最適化するように設計された静的型付き関数型プログラミング言語です。S式ベースの構文、Hindley-Milner型推論、そして純粋関数型の設計により、AIとの対話的なプログラミングを可能にします。

このチュートリアルでは、XS言語の基本的な使い方から高度な機能まで、実例を通じて学んでいきます。

## インストール

```bash
# リポジトリをクローン
git clone https://github.com/your-username/xs-lang-v3.git
cd xs-lang-v3

# ビルド
cargo build --release

# パスに追加（オプション）
export PATH=$PATH:$(pwd)/target/release
```

## 基本的な使い方

### Hello, World!

最初のXSプログラムを書いてみましょう。

```lisp
; hello.xs
(print "Hello, World!")
```

実行方法：
```bash
xsc run hello.xs
```

### 変数と関数

XS言語では、`let` で変数を定義し、`fn` で関数を定義します。

```lisp
; 変数の定義
(let x 42)
(let name "Alice")

; 関数の定義
(let double (fn (x) (* x 2)))
(let greet (fn (name) (concat "Hello, " name)))

; 関数の使用
(print (double 21))      ; => 42
(print (greet "Bob"))    ; => "Hello, Bob"
```

### 型注釈

型推論が働くため型注釈は省略可能ですが、明示的に指定することもできます。

```lisp
; 型注釈付きの変数
(let x : Int 42)
(let pi : Float 3.14159)

; 型注釈付きの関数
(let add : (-> Int Int Int) 
  (fn (x : Int y : Int) (+ x y)))
```

## 基本的なデータ型

### 数値

```lisp
; 整数
(let age 25)
(let year 2024)

; 浮動小数点数
(let pi 3.14159)
(let e 2.71828)

; 算術演算
(+ 1 2)         ; => 3
(- 10 3)        ; => 7
(* 4 5)         ; => 20
(/ 15 3)        ; => 5
(% 17 5)        ; => 2
```

### 真偽値

```lisp
(let is_ready true)
(let is_done false)

; 比較演算
(< 1 2)         ; => true
(> 5 3)         ; => true
(<= 3 3)        ; => true
(>= 4 5)        ; => false
(= 42 42)       ; => true
```

### 文字列

```lisp
(let message "Hello, XS!")
(let empty "")

; 文字列連結
(concat "Hello, " "World!")  ; => "Hello, World!"
```

### リスト

```lisp
; リストの作成
(let numbers (list 1 2 3 4 5))
(let empty_list (list))

; cons でリストを構築
(cons 0 (list 1 2 3))  ; => (list 0 1 2 3)

; リスト操作（標準ライブラリを使用）
(import List)
(List.map (fn (x) (* x 2)) (list 1 2 3))  ; => (list 2 4 6)
(List.filter (fn (x) (> x 2)) (list 1 2 3 4))  ; => (list 3 4)
```

## 制御構造

### if式

```lisp
(let age 18)
(if (>= age 18)
    "Adult"
    "Minor")

; ネストしたif
(let score 85)
(if (>= score 90)
    "A"
    (if (>= score 80)
        "B"
        (if (>= score 70)
            "C"
            "F")))
```

### パターンマッチング

```lisp
; リストのパターンマッチング
(let sum_list (fn (lst)
  (match lst
    ((list) 0)                          ; 空リスト
    ((list head tail) (+ head (sum_list tail))))))  ; cons パターン

; 使用例
(sum_list (list 1 2 3 4 5))  ; => 15
```

### let-in式（ローカルバインディング）

```lisp
; ローカル変数の定義
(let result
  (let x 10 in
    (let y 20 in
      (+ x y))))  ; => 30

; 関数内でのlet-in
(let calculate (fn (a b)
  (let sum (+ a b) in
    (let product (* a b) in
      (if (> sum product)
          sum
          product)))))
```

## 関数型プログラミング

### 高階関数

```lisp
; 関数を引数に取る関数
(let apply_twice (fn (f x) (f (f x))))
(apply_twice (fn (n) (* n 2)) 3)  ; => 12

; 関数を返す関数
(let make_adder (fn (n)
  (fn (x) (+ x n))))

(let add5 (make_adder 5))
(add5 10)  ; => 15
```

### カリー化と部分適用

XS言語では、複数引数の関数は自動的にカリー化されます。

```lisp
; カリー化された関数
(let add (fn (x y) (+ x y)))

; 部分適用
(let inc (add 1))
(inc 10)  ; => 11

; 3引数の関数
(let add3 (fn (x y z) (+ (+ x y) z)))
(let add_5_and_10 (add3 5 10))
(add_5_and_10 15)  ; => 30
```

### 関数合成

```lisp
(import Core)

; 関数合成
(let double (fn (x) (* x 2)))
(let inc (fn (x) (+ x 1)))

(let double_then_inc (Core.compose inc double))
(double_then_inc 5)  ; => 11
```

## 再帰関数

### rec構文

```lisp
; 階乗
(rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(factorial 5)  ; => 120

; フィボナッチ数列
(rec fib (n)
  (if (<= n 1)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

(fib 10)  ; => 55
```

### letRec（相互再帰）

```lisp
; 偶数・奇数の判定（相互再帰）
(letRec even (n) 
  (if (= n 0) 
      true 
      (odd (- n 1))))

(letRec odd (n) 
  (if (= n 0) 
      false 
      (even (- n 1))))

(even 10)  ; => true
(odd 7)    ; => true
```

## 代数的データ型

### 型定義

```lisp
; Option型
(type Option a
  (None)
  (Some a))

; 使用例
(let find_first (fn (pred lst)
  (match lst
    ((list) (None))
    ((list h t) 
      (if (pred h)
          (Some h)
          (find_first pred t))))))

; Result型
(type Result e a
  (Error e)
  (Ok a))

; 二分木
(type Tree a
  (Leaf)
  (Node a (Tree a) (Tree a)))
```

### パターンマッチングでの使用

```lisp
; Option型の処理
(let unwrap_or (fn (default opt)
  (match opt
    ((None) default)
    ((Some value) value))))

; 二分木の走査
(rec tree_sum (tree)
  (match tree
    ((Leaf) 0)
    ((Node val left right)
      (+ val (+ (tree_sum left) (tree_sum right))))))

; 使用例
(let my_tree 
  (Node 5 
    (Node 3 (Leaf) (Leaf))
    (Node 7 (Leaf) (Leaf))))

(tree_sum my_tree)  ; => 15
```

## モジュールシステム

### モジュールの定義

```lisp
; math_utils.xs
(module MathUtils
  (export square cube pow factorial)
  
  (define square (fn (x) (* x x)))
  (define cube (fn (x) (* x (square x))))
  
  (rec pow (base exp)
    (if (= exp 0)
        1
        (* base (pow base (- exp 1)))))
  
  (rec factorial (n)
    (if (= n 0)
        1
        (* n (factorial (- n 1))))))
```

### モジュールの使用

```lisp
; モジュールのインポート
(import MathUtils)

; 修飾名でアクセス
(MathUtils.square 5)     ; => 25
(MathUtils.factorial 5)  ; => 120

; エイリアス付きインポート
(import MathUtils as Math)
(Math.cube 3)  ; => 27
```

## 標準ライブラリ

XS言語には便利な標準ライブラリが付属しています。

### Core（基本関数）

```lisp
(import Core)

; 恒等関数
(Core.id 42)  ; => 42

; 定数関数
(let always_5 (Core.const 5))
(always_5 "ignored")  ; => 5

; 関数合成
(let f (Core.compose inc double))
(f 10)  ; => 21
```

### List（リスト操作）

```lisp
(import List)

; map: 各要素に関数を適用
(List.map (fn (x) (* x 2)) (list 1 2 3))  ; => (list 2 4 6)

; filter: 条件を満たす要素を抽出
(List.filter (fn (x) (> x 2)) (list 1 2 3 4))  ; => (list 3 4)

; fold-left: 左からの畳み込み
(List.fold-left (fn (acc x) (+ acc x)) 0 (list 1 2 3 4))  ; => 10

; range: 範囲リストの生成
(List.range 1 5)  ; => (list 1 2 3 4 5)
```

### Math（数学関数）

```lisp
(import Math)

; 累乗
(Math.pow 2 8)  ; => 256

; 最大公約数
(Math.gcd 48 18)  ; => 6

; 偶数・奇数判定
(Math.even 10)  ; => true
(Math.odd 7)    ; => true
```

## XS Shell (REPL)

XS Shellは対話的な開発環境です。

### 基本コマンド

```
xs> (let double (fn (x) (* x 2)))
double : (-> Int Int) = <closure>
  [bac2c0f3]

xs> (double 21)
42 : Int
  [af3d2e89]

xs> ls
double : (-> Int Int) = <closure> [bac2c0f3]

xs> name bac2 double_fn
Named double_fn : (-> Int Int) = <closure> [bac2c0f3]

xs> update
Updated 1 definitions:
+ double_fn
```

### コマンド一覧

- `help` - ヘルプ表示
- `history [n]` - 評価履歴表示
- `ls` - 定義された名前の一覧
- `name <hash> <name>` - ハッシュに名前を付ける
- `update` - 変更をコードベースにコミット
- `edits` - 保留中の編集を表示

## エラーハンドリング

XS言語は、AIフレンドリーなエラーメッセージを提供します。

```lisp
; 型エラーの例
xs> (+ "hello" 42)
ERROR[TYPE]: Type mismatch: expected Int, found String
Location: line 1, column 4
Code: (+ "hello" 42)
        ^^^^^^^
Suggestions:
  1. Convert string to integer using 'int_of_string'
     Replace with: (int_of_string "hello")

; 未定義変数の例
xs> (foo 42)
ERROR[SCOPE]: Undefined variable 'foo'
Location: line 1, column 2
Code: (foo 42)
       ^^^
Did you mean: 'fst' (distance: 2)
```

## 実践例：クイックソート

```lisp
(import List)

(rec quicksort (lst)
  (match lst
    ((list) (list))
    ((list pivot rest)
      (let smaller (List.filter (fn (x) (< x pivot)) rest) in
        (let larger (List.filter (fn (x) (>= x pivot)) rest) in
          (List.append (quicksort smaller)
                       (cons pivot (quicksort larger))))))))

; 使用例
(quicksort (list 3 1 4 1 5 9 2 6))  ; => (list 1 1 2 3 4 5 6 9)
```

## まとめ

このチュートリアルでは、XS言語の基本的な機能を紹介しました：

1. **基本構文**: S式ベースの簡潔な構文
2. **型システム**: 強力な型推論とオプショナルな型注釈
3. **関数型プログラミング**: 高階関数、カリー化、関数合成
4. **パターンマッチング**: 代数的データ型との組み合わせ
5. **モジュールシステム**: コードの構造化と再利用
6. **標準ライブラリ**: 実用的なユーティリティ関数
7. **対話的開発**: XS Shellによる実験的プログラミング

XS言語の詳細な仕様については、[言語リファレンス](../reference/language-reference.md)を参照してください。

## 次のステップ

- [高度な機能](advanced-features.md) - エフェクトシステム、Perceusメモリ管理など
- [WebAssemblyへのコンパイル](wasm-compilation.md) - ブラウザやWASIでの実行
- [AIとの協調プログラミング](ai-collaboration.md) - AIツールとの統合方法
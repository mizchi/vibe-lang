# XS言語における再帰構文の設計

## 背景

現在の`letRec`構文には型推論の問題があり、より言語に適した再帰表現を検討する。F#などの明示的な再帰宣言を持つ言語を参考に、AI向け静的解析言語として最適な構文を設計する。

## 他言語の再帰構文

### F# / OCaml
```fsharp
// 単純な再帰
let rec factorial n =
    if n <= 1 then 1
    else n * factorial (n - 1)

// 相互再帰
let rec even n = 
    if n = 0 then true
    else odd (n - 1)
and odd n =
    if n = 0 then false
    else even (n - 1)
```

### Scheme
```scheme
; 暗黙的に再帰可能
(define (factorial n)
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))
```

### Clojure
```clojure
; defnで定義、recurで末尾再帰
(defn factorial [n]
  (loop [n n acc 1]
    (if (<= n 1)
      acc
      (recur (dec n) (* acc n)))))
```

### Haskell
```haskell
-- すべての定義がデフォルトで再帰可能
factorial n 
  | n <= 1    = 1
  | otherwise = n * factorial (n - 1)
```

## XS言語への提案

### 提案1: 専用の関数定義フォーム `defun`

```lisp
; 非再帰関数
(let double (lambda (x) (* x 2)))

; 再帰関数は defun で定義
(defun factorial (n)
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))

; 型アノテーション付き
(defun factorial (n : Int) : Int
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))
```

**利点:**
- 再帰と非再帰が構文レベルで明確に区別される
- 静的解析が容易
- 型推論の実装が単純化

**欠点:**
- 新しいキーワードの導入
- 高階関数として扱いにくい

### 提案2: `rec` 修飾子

```lisp
; rec修飾子で再帰を明示
(let rec factorial 
  (lambda (n)
    (if (<= n 1)
        1
        (* n (factorial (- n 1))))))

; 型アノテーション付き
(let rec factorial : (-> Int Int)
  (lambda (n)
    (if (<= n 1)
        1
        (* n (factorial (- n 1))))))
```

**利点:**
- 現在の構文に近い
- letの拡張として自然

**欠点:**
- パース時の曖昧性

### 提案3: `letrec` フォーム（相互再帰対応）

```lisp
; 単一の再帰関数
(letrec ((factorial (lambda (n)
                      (if (<= n 1)
                          1
                          (* n (factorial (- n 1)))))))
  factorial)

; 相互再帰
(letrec ((even (lambda (n)
                 (if (= n 0)
                     true
                     (odd (- n 1)))))
         (odd (lambda (n)
                (if (= n 0)
                    false
                    (even (- n 1))))))
  (list even odd))
```

**利点:**
- Scheme由来で理論的に確立
- 相互再帰が自然に表現可能
- スコープが明確

**欠点:**
- ネストが深くなりがち
- トップレベル定義には不向き

### 提案4: `define` + `rec` アトリビュート

```lisp
; トップレベル定義
(define factorial #:rec
  (lambda (n)
    (if (<= n 1)
        1
        (* n (factorial (- n 1))))))

; 相互再帰はグループ化
(define-rec-group
  (even (lambda (n)
          (if (= n 0) true (odd (- n 1)))))
  (odd (lambda (n)
         (if (= n 0) false (even (- n 1))))))
```

**利点:**
- メタデータとして再帰性を表現
- 拡張性が高い

**欠点:**
- 構文が複雑

### 提案5: Clojureスタイルの`recur`

```lisp
(let factorial
  (lambda (n)
    (let loop ((n n) (acc 1))
      (if (<= n 1)
          acc
          (recur (- n 1) (* acc n))))))
```

**利点:**
- 末尾再帰最適化が保証される
- スタックオーバーフローを防げる

**欠点:**
- 相互再帰が表現できない
- 末尾位置でしか使えない

## 推奨案: ハイブリッドアプローチ

XS言語の特性（AI向け静的解析、S式、明示的型付け）を考慮し、以下のハイブリッドアプローチを推奨：

### 1. 基本的な再帰: `rec` キーワード

```lisp
; シンプルな rec フォーム
(rec factorial (n)
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))

; 型アノテーション付き
(rec factorial (n : Int) : Int
  (if (<= n 1)
      1
      (* n (factorial (- n 1)))))

; let束縛として使用
(let fact (rec f (n) 
            (if (<= n 1) 1 (* n (f (- n 1))))))
```

### 2. 相互再帰: `rec-group`

```lisp
(rec-group
  ((even (n) (if (= n 0) true (odd (- n 1))))
   (odd (n) (if (= n 0) false (even (- n 1)))))
  ; ここで even と odd が使用可能
  (list even odd))
```

### 3. 末尾再帰最適化: `recur`

```lisp
(rec sum-list (lst)
  (rec-loop ((lst lst) (acc 0))
    (if (null? lst)
        acc
        (recur (cdr lst) (+ acc (car lst))))))
```

## 実装方針

1. **型推論の簡略化**
   - `rec`フォームでは関数の型を事前に型環境に追加
   - 本体の型チェック時に自己参照を解決

2. **静的解析の最適化**
   - 再帰呼び出しグラフの構築が容易
   - 終了性解析のためのアノテーション追加可能

3. **段階的な実装**
   - まず`rec`フォームを実装
   - 次に`rec-group`で相互再帰
   - 最後に`recur`で末尾再帰最適化

## まとめ

XS言語には、明示的で解析しやすい`rec`フォームを基本とし、必要に応じて相互再帰や末尾再帰最適化をサポートする構文を採用することを推奨する。これにより：

- AIによる静的解析が容易
- 型推論の実装が単純
- 再帰の意図が明確
- 段階的な機能拡張が可能

となる。
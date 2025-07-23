# XS言語 チュートリアル - 第2章: パターンマッチング

この章では、XS Shellを使ってパターンマッチングを学びます。前章から続けている場合は、そのままXS Shellで作業を続けられます。新しく始める場合は、XS Shellを起動してください。

```bash
$ cargo run --bin xsc -- shell
```

## パターンマッチングとは

パターンマッチングは、データの構造を調べて、その構造に応じて処理を分岐する強力な機能です。まず簡単な例から始めましょう。

## 数値のパターンマッチング

`match`式の基本的な使い方：

```
xs> (let checkNumber (fn (n) 
      (match n
        (0 "zero")
        (1 "one")
        (2 "two")
        (_ "other"))))
checkNumber : (-> Int String) = <closure>
  [hash...]

xs> (checkNumber 0)
"zero" : String
  [hash...]

xs> (checkNumber 1)
"one" : String
  [hash...]

xs> (checkNumber 99)
"other" : String
  [hash...]
```

`_`（アンダースコア）は、どんな値にもマッチするワイルドカードパターンです。

## 変数パターン

マッチした値を変数に束縛できます：

```
xs> (let describe (fn (x)
      (match x
        (0 "it's zero")
        (n (strConcat "the number is " (intToString n))))))
describe : (-> Int String) = <closure>
  [hash...]

xs> (describe 0)
"it's zero" : String
  [hash...]

xs> (describe 42)
"the number is 42" : String
  [hash...]
```

## リストのパターンマッチング - 基本

空リストと要素を持つリストを区別：

```
xs> (let isEmpty (fn (lst)
      (match lst
        ((list) true)
        (_ false))))
isEmpty : (-> (List t0) Bool) = <closure>
  [hash...]

xs> (isEmpty (list))
true : Bool
  [hash...]

xs> (isEmpty (list 1 2 3))
false : Bool
  [hash...]
```

## リストの要素数によるパターンマッチング

```
xs> (let countElements (fn (lst)
      (match lst
        ((list) "empty")
        ((list x) "one element")
        ((list x y) "two elements")
        ((list x y z) "three elements")
        (_ "many elements"))))
countElements : (-> (List t0) String) = <closure>
  [hash...]

xs> (countElements (list))
"empty" : String
  [hash...]

xs> (countElements (list 10))
"one element" : String
  [hash...]

xs> (countElements (list 10 20))
"two elements" : String
  [hash...]

xs> (countElements (list 1 2 3 4 5))
"many elements" : String
  [hash...]
```

## head/tailパターン（...を使用）

リストを先頭要素と残りに分解する重要なパターン：

```
xs> (let head (fn (lst)
      (match lst
        ((list) "empty list")
        ((list h ... rest) h))))
head : (-> (List t0) t0) = <closure>
  [hash...]

xs> (head (list 10 20 30))
10 : Int
  [hash...]

xs> (let tail (fn (lst)
      (match lst
        ((list) (list))
        ((list h ... rest) rest))))
tail : (-> (List t0) (List t0)) = <closure>
  [hash...]

xs> (tail (list 10 20 30))
(list 20 30) : (List Int)
  [hash...]
```

`...`は「残りの要素」を表す特別な記法です。

## 再帰的なリスト処理

パターンマッチングと再帰を組み合わせて、リストを処理する関数を作りましょう。

### リストの長さを計算

```
xs> (rec length (lst)
      (match lst
        ((list) 0)
        ((list h ... rest) (+ 1 (length rest)))))
length : (-> (List t0) Int) = <rec-closure>
  [hash...]

xs> (length (list))
0 : Int
  [hash...]

xs> (length (list 10 20 30 40 50))
5 : Int
  [hash...]
```

### リストの合計

```
xs> (rec sum (lst)
      (match lst
        ((list) 0)
        ((list h ... rest) (+ h (sum rest)))))
sum : (-> (List Int) Int) = <rec-closure>
  [hash...]

xs> (sum (list 1 2 3 4 5))
15 : Int
  [hash...]

xs> (sum (list 10 20 30))
60 : Int
  [hash...]
```

### リストの要素を2倍にする

```
xs> (rec doubleAll (lst)
      (match lst
        ((list) (list))
        ((list h ... rest) 
          (cons (* h 2) (doubleAll rest)))))
doubleAll : (-> (List Int) (List Int)) = <rec-closure>
  [hash...]

xs> (doubleAll (list 1 2 3 4 5))
(list 2 4 6 8 10) : (List Int)
  [hash...]
```

## 複数の要素を取り出す

最初の複数要素を一度に取り出すこともできます：

```
xs> (let sumFirstTwo (fn (lst)
      (match lst
        ((list) 0)
        ((list x) x)
        ((list x y ... rest) (+ x y)))))
sumFirstTwo : (-> (List Int) Int) = <closure>
  [hash...]

xs> (sumFirstTwo (list 10 20 30 40))
30 : Int
  [hash...]

xs> (sumFirstTwo (list 5))
5 : Int
  [hash...]
```

## 代数的データ型の定義とパターンマッチング

### Option型を定義して使う

```
xs> (type Option a
      (None)
      (Some a))
Type Option defined
  [hash...]

xs> (let safeDivide (fn (x y)
      (if (= y 0)
          (None)
          (Some (/ x y)))))
safeDivide : (-> Int (-> Int (Option Int))) = <closure>
  [hash...]

xs> (safeDivide 10 2)
(Some 5) : (Option Int)
  [hash...]

xs> (safeDivide 10 0)
(None) : (Option Int)
  [hash...]
```

Option型の値を処理：

```
xs> (let getOrDefault (fn (opt default)
      (match opt
        ((None) default)
        ((Some value) value))))
getOrDefault : (-> (Option t0) (-> t0 t0)) = <closure>
  [hash...]

xs> (getOrDefault (Some 42) 0)
42 : Int
  [hash...]

xs> (getOrDefault (None) 0)
0 : Int
  [hash...]
```

### Result型

```
xs> (type Result e a
      (Error e)
      (Ok a))
Type Result defined
  [hash...]

xs> (let parsePositive (fn (n)
      (if (< n 0)
          (Error "negative number")
          (Ok n))))
parsePositive : (-> Int (Result String Int)) = <closure>
  [hash...]

xs> (parsePositive 42)
(Ok 42) : (Result String Int)
  [hash...]

xs> (parsePositive -5)
(Error "negative number") : (Result String Int)
  [hash...]
```

## 実践的な例：フィルタリング

パターンマッチングを使って、条件を満たす要素だけを抽出：

```
xs> (rec filter (pred lst)
      (match lst
        ((list) (list))
        ((list h ... rest)
          (if (pred h)
              (cons h (filter pred rest))
              (filter pred rest)))))
filter : (-> (-> t0 Bool) (-> (List t0) (List t0))) = <rec-closure>
  [hash...]

xs> (let isEven (fn (n) (= (% n 2) 0)))
isEven : (-> Int Bool) = <closure>
  [hash...]

xs> (filter isEven (list 1 2 3 4 5 6 7 8))
(list 2 4 6 8) : (List Int)
  [hash...]
```

## リストの反転

より複雑な例として、リストを反転する関数を作ります：

```
xs> (rec reverseHelper (lst acc)
      (match lst
        ((list) acc)
        ((list h ... rest) (reverseHelper rest (cons h acc)))))
reverseHelper : (-> (List t0) (-> (List t0) (List t0))) = <rec-closure>
  [hash...]

xs> (let reverse (fn (lst) (reverseHelper lst (list))))
reverse : (-> (List t0) (List t0)) = <closure>
  [hash...]

xs> (reverse (list 1 2 3 4 5))
(list 5 4 3 2 1) : (List Int)
  [hash...]
```

## ネストしたパターン

リストのリストなど、ネストした構造もパターンマッチングできます：

```
xs> (let sumPairs (fn (lst)
      (match lst
        ((list) 0)
        ((list (list a b)) (+ a b))
        ((list (list a b) ... rest)
          (+ (+ a b) (sumPairs rest)))
        (_ 0))))
sumPairs : (-> (List (List Int)) Int) = <closure>
  [hash...]

xs> (sumPairs (list (list 1 2) (list 3 4) (list 5 6)))
21 : Int
  [hash...]
```

## 練習

以下の関数を実装してみましょう：

1. リストの最大値を求める関数（空リストの場合はOptionを使う）
2. リストから重複を除去する関数
3. 2つのリストを結合する`append`関数

解答例：

```
xs> (rec maxList (lst)
      (match lst
        ((list) (None))
        ((list x) (Some x))
        ((list h ... rest)
          (match (maxList rest)
            ((None) (Some h))
            ((Some m) (Some (if (> h m) h m)))))))

xs> (maxList (list 3 1 4 1 5 9))
(Some 9) : (Option Int)

xs> (rec append (lst1 lst2)
      (match lst1
        ((list) lst2)
        ((list h ... rest) (cons h (append rest lst2)))))

xs> (append (list 1 2 3) (list 4 5 6))
(list 1 2 3 4 5 6) : (List Int)
```

## まとめ

この章では、パターンマッチングについて学びました：

- `match`式の基本的な使い方
- リストのパターンマッチング（空リスト、要素の取り出し）
- head/tailパターン（`...`記法）
- 再帰的なリスト処理
- 代数的データ型（Option、Result）との組み合わせ
- ネストしたパターン

パターンマッチングは、XS言語でデータ構造を扱う際の中心的な機能です。次章では、高階関数と関数型プログラミングのテクニックについて学びます。
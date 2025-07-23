# XS言語 チュートリアル - 第3章: 関数型プログラミング

この章では、XS Shellを使って高階関数と関数型プログラミングのテクニックを学びます。前章で定義した関数も使いながら進めていきます。

```bash
$ cargo run --bin xsc -- shell
```

## 高階関数とは

高階関数は、関数を引数として受け取るか、関数を返す関数です。まず、前章で作った関数を思い出してみましょう。

## map - リストの変換

`map`は、リストの各要素に関数を適用する高階関数です：

```
xs> (rec map (f lst)
      (match lst
        ((list) (list))
        ((list h ... rest) (cons (f h) (map f rest)))))
map : (-> (-> t0 t1) (-> (List t0) (List t1))) = <rec-closure>
  [hash...]

xs> (let double (fn (x) (* x 2)))
double : (-> Int Int) = <closure>
  [hash...]

xs> (map double (list 1 2 3 4 5))
(list 2 4 6 8 10) : (List Int)
  [hash...]
```

無名関数を直接渡すこともできます：

```
xs> (map (fn (x) (+ x 10)) (list 1 2 3))
(list 11 12 13) : (List Int)
  [hash...]

xs> (map (fn (s) (strConcat s "!")) (list "Hello" "World"))
(list "Hello!" "World!") : (List String)
  [hash...]
```

## filter - 条件による選択

前章で定義した`filter`を使ってみましょう：

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

xs> (filter isEven (list 1 2 3 4 5 6 7 8 9 10))
(list 2 4 6 8 10) : (List Int)
  [hash...]
```

複数の条件を組み合わせる：

```
xs> (let isPositiveEven (fn (n) 
      (and (> n 0) (isEven n))))
isPositiveEven : (-> Int Bool) = <closure>
  [hash...]

xs> (filter isPositiveEven (list -4 -2 0 2 4 6))
(list 2 4 6) : (List Int)
  [hash...]
```

## fold - リストの畳み込み

`fold`は、リストを単一の値に集約する強力な高階関数です。

### foldLeft（左畳み込み）

```
xs> (rec foldLeft (f init lst)
      (match lst
        ((list) init)
        ((list h ... rest) 
          (foldLeft f (f init h) rest))))
foldLeft : (-> (-> t0 (-> t1 t0)) (-> t0 (-> (List t1) t0))) = <rec-closure>
  [hash...]

xs> (foldLeft (fn (acc x) (+ acc x)) 0 (list 1 2 3 4 5))
15 : Int
  [hash...]

xs> (foldLeft (fn (acc x) (* acc x)) 1 (list 1 2 3 4 5))
120 : Int
  [hash...]
```

### foldRight（右畳み込み）

```
xs> (rec foldRight (f init lst)
      (match lst
        ((list) init)
        ((list h ... rest) 
          (f h (foldRight f init rest)))))
foldRight : (-> (-> t0 (-> t1 t1)) (-> t1 (-> (List t0) t1))) = <rec-closure>
  [hash...]

xs> (foldRight cons (list) (list 1 2 3))
(list 1 2 3) : (List Int)
  [hash...]
```

## カリー化の活用

XS言語の関数は自動的にカリー化されます。これを活用してみましょう。

### 設定可能な関数を作る

```
xs> (let multiply (fn (factor x) (* factor x)))
multiply : (-> Int (-> Int Int)) = <closure>
  [hash...]

xs> (let double (multiply 2))
double : (-> Int Int) = <closure>
  [hash...]

xs> (let triple (multiply 3))
triple : (-> Int Int) = <closure>
  [hash...]

xs> (let tenTimes (multiply 10))
tenTimes : (-> Int Int) = <closure>
  [hash...]

xs> (map double (list 1 2 3 4 5))
(list 2 4 6 8 10) : (List Int)
  [hash...]

xs> (map triple (list 1 2 3 4 5))
(list 3 6 9 12 15) : (List Int)
  [hash...]
```

### フィルタリング条件の生成

```
xs> (let greaterThan (fn (threshold x) 
      (> x threshold)))
greaterThan : (-> Int (-> Int Bool)) = <closure>
  [hash...]

xs> (let isPositive (greaterThan 0))
isPositive : (-> Int Bool) = <closure>
  [hash...]

xs> (let isLarge (greaterThan 100))
isLarge : (-> Int Bool) = <closure>
  [hash...]

xs> (filter isPositive (list -5 -2 0 3 7 10))
(list 3 7 10) : (List Int)
  [hash...]

xs> (filter isLarge (list 50 150 75 200 125))
(list 150 200 125) : (List Int)
  [hash...]
```

## 関数合成

関数を組み合わせて新しい関数を作ります：

```
xs> (let compose (fn (f g)
      (fn (x) (f (g x)))))
compose : (-> (-> t0 t1) (-> (-> t2 t0) (-> t2 t1))) = <closure>
  [hash...]

xs> (let addOne (fn (x) (+ x 1)))
addOne : (-> Int Int) = <closure>
  [hash...]

xs> (let double (fn (x) (* x 2)))
double : (-> Int Int) = <closure>
  [hash...]

xs> (let doubleAndAddOne (compose addOne double))
doubleAndAddOne : (-> Int Int) = <closure>
  [hash...]

xs> (doubleAndAddOne 5)
11 : Int  ; (5 * 2) + 1
  [hash...]

xs> (let addOneAndDouble (compose double addOne))
addOneAndDouble : (-> Int Int) = <closure>
  [hash...]

xs> (addOneAndDouble 5)
12 : Int  ; (5 + 1) * 2
  [hash...]
```

## パイプライン処理

データを段階的に変換する処理を作ってみましょう：

```
xs> (let |> (fn (x f) (f x)))
|> : (-> t0 (-> (-> t0 t1) t1)) = <closure>
  [hash...]

xs> (|> 5
      (fn (x) (* x 2))
      (fn (x) (|> x
        (fn (y) (+ y 3))
        (fn (y) (|> y
          (fn (z) (- z 1)))))))
12 : Int  ; ((5 * 2) + 3) - 1
  [hash...]
```

より実践的な例：

```
xs> (let processNumbers (fn (lst)
      (|> lst
        (fn (l) (filter isPositive l))
        (fn (l) (|> l
          (fn (l2) (map double l2))
          (fn (l2) (|> l2
            (fn (l3) (filter (greaterThan 10) l3)))))))))
processNumbers : (-> (List Int) (List Int)) = <closure>
  [hash...]

xs> (processNumbers (list -5 3 8 -2 6 12 1))
(list 16 12 24) : (List Int)
  [hash...]
```

## 実践的な例：リスト処理ユーティリティ

### zipWith - 2つのリストを結合

```
xs> (rec zipWith (f lst1 lst2)
      (match lst1
        ((list) (list))
        ((list h1 ... rest1)
          (match lst2
            ((list) (list))
            ((list h2 ... rest2)
              (cons (f h1 h2) 
                    (zipWith f rest1 rest2)))))))
zipWith : (-> (-> t0 (-> t1 t2)) (-> (List t0) (-> (List t1) (List t2)))) = <rec-closure>
  [hash...]

xs> (zipWith (fn (x y) (+ x y)) 
             (list 1 2 3) 
             (list 10 20 30))
(list 11 22 33) : (List Int)
  [hash...]

xs> (zipWith (fn (x y) (list x y)) 
             (list "a" "b" "c") 
             (list 1 2 3))
(list (list "a" 1) (list "b" 2) (list "c" 3)) : (List (List t0))
  [hash...]
```

### takeWhile - 条件を満たす間だけ取得

```
xs> (rec takeWhile (pred lst)
      (match lst
        ((list) (list))
        ((list h ... rest)
          (if (pred h)
              (cons h (takeWhile pred rest))
              (list)))))
takeWhile : (-> (-> t0 Bool) (-> (List t0) (List t0))) = <rec-closure>
  [hash...]

xs> (takeWhile (fn (x) (< x 5)) (list 1 3 5 7 2 4))
(list 1 3) : (List Int)
  [hash...]

xs> (takeWhile isPositive (list 3 5 2 -1 4 6))
(list 3 5 2) : (List Int)
  [hash...]
```

### flatten - リストのリストを平坦化

```
xs> (rec append (lst1 lst2)
      (match lst1
        ((list) lst2)
        ((list h ... rest) 
          (cons h (append rest lst2)))))
append : (-> (List t0) (-> (List t0) (List t0))) = <rec-closure>
  [hash...]

xs> (rec flatten (lstOfLsts)
      (match lstOfLsts
        ((list) (list))
        ((list lst ... rest)
          (append lst (flatten rest)))))
flatten : (-> (List (List t0)) (List t0)) = <rec-closure>
  [hash...]

xs> (flatten (list (list 1 2) (list 3 4) (list 5)))
(list 1 2 3 4 5) : (List Int)
  [hash...]
```

## Option型を使った安全な処理

前章で定義したOption型を使った高階関数：

```
xs> (let mapOption (fn (f opt)
      (match opt
        ((None) (None))
        ((Some x) (Some (f x))))))
mapOption : (-> (-> t0 t1) (-> (Option t0) (Option t1))) = <closure>
  [hash...]

xs> (mapOption double (Some 21))
(Some 42) : (Option Int)
  [hash...]

xs> (mapOption double (None))
(None) : (Option Int)
  [hash...]
```

Option型のチェーン処理：

```
xs> (let bindOption (fn (opt f)
      (match opt
        ((None) (None))
        ((Some x) (f x)))))
bindOption : (-> (Option t0) (-> (-> t0 (Option t1)) (Option t1))) = <closure>
  [hash...]

xs> (let safeDivide (fn (x y)
      (if (= y 0) (None) (Some (/ x y)))))
safeDivide : (-> Int (-> Int (Option Int))) = <closure>
  [hash...]

xs> (bindOption (Some 20)
      (fn (x) (bindOption (safeDivide x 2)
        (fn (y) (Some (* y 3))))))
(Some 30) : (Option Int)  ; (20 / 2) * 3
  [hash...]
```

## 練習

以下の関数を実装してみましょう：

1. `flatMap` - mapしてからflattenする関数
2. `partition` - リストを条件で2つに分割する関数
3. `all` と `any` - すべて/いずれかが条件を満たすか確認

解答例：

```
xs> (let flatMap (fn (f lst)
      (flatten (map f lst))))
flatMap : (-> (-> t0 (List t1)) (-> (List t0) (List t1))) = <closure>

xs> (flatMap (fn (x) (list x (* x 2))) (list 1 2 3))
(list 1 2 2 4 3 6) : (List Int)

xs> (let partition (fn (pred lst)
      (foldRight 
        (fn (x acc)
          (match acc
            ((list trues falses)
              (if (pred x)
                  (list (cons x trues) falses)
                  (list trues (cons x falses))))))
        (list (list) (list))
        lst)))

xs> (partition isEven (list 1 2 3 4 5 6))
(list (list 2 4 6) (list 1 3 5)) : (List (List Int))
```

## まとめ

この章では、関数型プログラミングの重要な概念を学びました：

- 高階関数（map、filter、fold）
- カリー化と部分適用の活用
- 関数合成
- パイプライン処理
- 実践的なリスト処理
- Option型を使った安全な処理

これらのテクニックを使うことで、より簡潔で保守しやすいコードを書くことができます。次章では、XS言語の特徴的な機能であるコンテンツアドレス型コードベース管理について学びます。
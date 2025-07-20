;; Pair (tuple) data structure

(module Pair
  (export Pair pair fst snd)
  
  ;; ペア型の定義
  (type Pair a b
    (Pair a b))
  
  ;; ペアを作成
  (let pair (fn (x y) (Pair x y)))
  
  ;; ペアの最初の要素を取得
  (let fst (fn (p)
    (match p
      ((Pair x y) x))))
  
  ;; ペアの2番目の要素を取得
  (let snd (fn (p)
    (match p
      ((Pair x y) y)))))
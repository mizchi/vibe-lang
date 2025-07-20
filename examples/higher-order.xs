; 高階関数の例

; map関数の実装と使用
(let map (fn (f xs)
  (match xs
    ((list) (list))
    ((cons head tail) (cons (f head) (map f tail))))))

; 2倍にする関数
(let double (fn (x) (* x 2)))

; リストの各要素を2倍にする
(map double (list 1 2 3 4 5))  ; => (list 2 4 6 8 10)

; filter関数の実装
(let filter (fn (pred xs)
  (match xs
    ((list) (list))
    ((cons head tail)
     (if (pred head)
         (cons head (filter pred tail))
         (filter pred tail))))))

; 偶数判定
(let even? (fn (x) (= (% x 2) 0)))

; 偶数のみ抽出
(filter even? (list 1 2 3 4 5 6))  ; => (list 2 4 6)

; fold関数（左畳み込み）
(let fold-left (fn (f init xs)
  (match xs
    ((list) init)
    ((cons head tail) (fold-left f (f init head) tail)))))

; リストの合計
(fold-left + 0 (list 1 2 3 4 5))  ; => 15

; 関数の合成
(let compose (fn (f g)
  (fn (x) (f (g x)))))

; 2倍して1を足す関数
(let double-plus-one (compose (fn (x) (+ x 1)) double))
(double-plus-one 5)  ; => 11
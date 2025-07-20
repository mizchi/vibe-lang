; リストユーティリティモジュール
(module ListUtils
  (export length head tail nth take drop filter map fold-left fold-right)
  
  ; リストの長さ
  (define length (rec len (list)
    (match list
      ((list) 0)
      ((list _ xs) (+ 1 (len xs))))))
  
  ; 先頭要素を取得
  (define head (fn (list)
    (match list
      ((list x _) (Some x))
      ((list) (None)))))
  
  ; 先頭以外を取得
  (define tail (fn (list)
    (match list
      ((list _ xs) xs)
      ((list) (list)))))
  
  ; n番目の要素を取得 (0-indexed)
  (define nth (rec get-nth (n list)
    (match list
      ((list) (None))
      ((list x xs)
       (if (= n 0)
           (Some x)
           (get-nth (- n 1) xs))))))
  
  ; 最初のn個を取得
  (define take (rec take-n (n list)
    (if (<= n 0)
        (list)
        (match list
          ((list) (list))
          ((list x xs) (cons x (take-n (- n 1) xs)))))))
  
  ; 最初のn個を除いたリストを返す
  (define drop (rec drop-n (n list)
    (if (<= n 0)
        list
        (match list
          ((list) (list))
          ((list _ xs) (drop-n (- n 1) xs))))))
  
  ; フィルタリング
  (define filter (rec do-filter (pred list)
    (match list
      ((list) (list))
      ((list x xs)
       (if (pred x)
           (cons x (do-filter pred xs))
           (do-filter pred xs))))))
  
  ; マップ
  (define map (rec do-map (f list)
    (match list
      ((list) (list))
      ((list x xs) (cons (f x) (do-map f xs))))))
  
  ; 左畳み込み
  (define fold-left (rec do-fold-left (f acc list)
    (match list
      ((list) acc)
      ((list x xs) (do-fold-left f (f acc x) xs)))))
  
  ; 右畳み込み
  (define fold-right (rec do-fold-right (f list acc)
    (match list
      ((list) acc)
      ((list x xs) (f x (do-fold-right f xs acc))))))
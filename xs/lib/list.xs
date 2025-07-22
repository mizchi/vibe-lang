;; XS Standard Library - List Operations
;; リスト操作のための関数群

;; List construction helpers
(let singleton (fn (x) (list x)))
(let pair (fn (x y) (list x y)))

;; List predicates
(rec null (xs)
  (match xs
    ((list) true)
    (_ false)))

;; List operations
(rec length (xs)
  (match xs
    ((list) 0)
    ((list h t) (+ 1 (length t)))))

(rec append (xs ys)
  (match xs
    ((list) ys)
    ((list h t) (cons h (append t ys)))))

(rec reverse (xs)
  (rec revHelper (xs acc)
    (match xs
      ((list) acc)
      ((list h t) (revHelper t (cons h acc)))))
  (revHelper xs (list)))

;; Higher-order list operations
(rec map (f xs)
  (match xs
    ((list) (list))
    ((list h t) (cons (f h) (map f t)))))

(rec filter (p xs)
  (match xs
    ((list) (list))
    ((list h t) 
      (if (p h)
          (cons h (filter p t))
          (filter p t)))))

(rec foldLeft (f acc xs)
  (match xs
    ((list) acc)
    ((list h t) (foldLeft f (f acc h) t))))

(rec foldRight (f xs acc)
  (match xs
    ((list) acc)
    ((list h t) (f h (foldRight f t acc)))))

;; List searching
(rec find (p xs)
  (match xs
    ((list) (Nothing))
    ((list h t)
      (if (p h)
          (Just h)
          (find p t)))))

(rec elem (x xs)
  (match xs
    ((list) false)
    ((list h t)
      (if (= x h)
          true
          (elem x t)))))

;; List manipulation
(rec take (n xs)
  (if (= n 0)
      (list)
      (match xs
        ((list) (list))
        ((list h t) (cons h (take (- n 1) t))))))

(rec drop (n xs)
  (if (= n 0)
      xs
      (match xs
        ((list) (list))
        ((list h t) (drop (- n 1) t)))))

(rec zip (xs ys)
  (match xs
    ((list) (list))
    ((list xh xt)
      (match ys
        ((list) (list))
        ((list yh yt) (cons (list xh yh) (zip xt yt)))))))

;; List generation
(rec range (start end)
  (if (> start end)
      (list)
      (cons start (range (+ start 1) end))))

(rec replicate (n x)
  (if (= n 0)
      (list)
      (cons x (replicate (- n 1) x))))

;; List predicates
(rec all (p xs)
  (match xs
    ((list) true)
    ((list h t)
      (if (p h)
          (all p t)
          false))))

(rec any (p xs)
  (match xs
    ((list) false)
    ((list h t)
      (if (p h)
          true
          (any p t)))))
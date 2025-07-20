;; XS Standard Library - Core Functions
;; 基本的な関数と演算子のラッパー

;; Function composition
(let compose (fn (f g) (fn (x) (f (g x)))))

;; Identity function
(let id (fn (x) x))

;; Constant function
(let const (fn (x) (fn (y) x)))

;; Flip function arguments
(let flip (fn (f) (fn (x y) (f y x))))

;; Tuple operations
(let fst (fn (pair) (match pair ((list x y) x))))
(let snd (fn (pair) (match pair ((list x y) y))))

;; Maybe type helpers
(type Maybe a (Just a) (Nothing))

(let maybe (fn (default f m)
  (match m
    ((Just x) (f x))
    ((Nothing) default))))

;; Either type helpers
(type Either a b (Left a) (Right b))

(let either (fn (f g e)
  (match e
    ((Left x) (f x))
    ((Right y) (g y)))))

;; Boolean operations
(let not (fn (b) (if b false true)))
(let and (fn (a b) (if a b false)))
(let or (fn (a b) (if a true b)))

;; Numeric operations
(let inc (fn (n) (+ n 1)))
(let dec (fn (n) (- n 1)))
(let double (fn (n) (* n 2)))
(let square (fn (n) (* n n)))
(let abs (fn (n) (if (< n 0) (- 0 n) n)))

;; Comparison helpers
(let min (fn (a b) (if (< a b) a b)))
(let max (fn (a b) (if (> a b) a b)))

;; Function application helpers
(let apply (fn (f x) (f x)))
(let pipe (fn (x f) (f x)))
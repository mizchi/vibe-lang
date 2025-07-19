;; XS Standard Library - Core Functions
;; 基本的な関数と演算子のラッパー

;; Function composition
(let compose (lambda (f g) (lambda (x) (f (g x)))))

;; Identity function
(let id (lambda (x) x))

;; Constant function
(let const (lambda (x) (lambda (y) x)))

;; Flip function arguments
(let flip (lambda (f) (lambda (x y) (f y x))))

;; Tuple operations
(let fst (lambda (pair) (match pair ((list x y) x))))
(let snd (lambda (pair) (match pair ((list x y) y))))

;; Maybe type helpers
(type Maybe a (Just a) (Nothing))

(let maybe (lambda (default f m)
  (match m
    ((Just x) (f x))
    ((Nothing) default))))

;; Either type helpers
(type Either a b (Left a) (Right b))

(let either (lambda (f g e)
  (match e
    ((Left x) (f x))
    ((Right y) (g y)))))

;; Boolean operations
(let not (lambda (b) (if b false true)))
(let and (lambda (a b) (if a b false)))
(let or (lambda (a b) (if a true b)))

;; Numeric operations
(let inc (lambda (n) (+ n 1)))
(let dec (lambda (n) (- n 1)))
(let double (lambda (n) (* n 2)))
(let square (lambda (n) (* n n)))
(let abs (lambda (n) (if (< n 0) (- 0 n) n)))

;; Comparison helpers
(let min (lambda (a b) (if (< a b) a b)))
(let max (lambda (a b) (if (> a b) a b)))

;; Function application helpers
(let apply (lambda (f x) (f x)))
(let pipe (lambda (x f) (f x)))
;; XS Standard Library - Math Operations
;; 数学関数と数値演算

;; Basic math operations
(let neg (lambda (x) (- 0 x)))
(let reciprocal (lambda (x) (/ 1.0 x)))

;; Exponentiation
(rec pow (base exp)
  (if (= exp 0)
      1
      (if (< exp 0)
          (/ 1 (pow base (neg exp)))
          (* base (pow base (- exp 1))))))

;; Factorial
(rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

;; GCD and LCM
(rec gcd (a b)
  (if (= b 0)
      a
      (gcd b (% a b))))

(let lcm (lambda (a b)
  (/ (* a b) (gcd a b))))

;; Number predicates
(let even (lambda (n) (= (% n 2) 0)))
(let odd (lambda (n) (not (even n))))
(let positive (lambda (n) (> n 0)))
(let negative (lambda (n) (< n 0)))
(let zero (lambda (n) (= n 0)))

;; Fibonacci sequence
(rec fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

;; More efficient tail-recursive fibonacci
(rec fib-tail (n)
  (rec fib-helper (n a b)
    (if (= n 0)
        a
        (fib-helper (- n 1) b (+ a b))))
  (fib-helper n 0 1))

;; Sum and product of lists
(let sum (lambda (xs) (fold-left + 0 xs)))
(let product (lambda (xs) (fold-left * 1 xs)))

;; Average
(let average (lambda (xs)
  (let len (length xs))
  (if (= len 0)
      0
      (/ (sum xs) len))))

;; Clamp value between min and max
(let clamp (lambda (min-val max-val x)
  (max min-val (min max-val x))))

;; Sign function
(let sign (lambda (x)
  (if (< x 0)
      -1
      (if (> x 0)
          1
          0))))
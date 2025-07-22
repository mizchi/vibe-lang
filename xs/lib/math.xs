;; XS Standard Library - Math Operations
;; 数学関数と数値演算

;; Basic math operations
(let neg (fn (x) (- 0 x)))
(let reciprocal (fn (x) (/ 1.0 x)))

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

(let lcm (fn (a b)
  (/ (* a b) (gcd a b))))

;; Number predicates
(let even (fn (n) (= (% n 2) 0)))
(let odd (fn (n) (not (even n))))
(let positive (fn (n) (> n 0)))
(let negative (fn (n) (< n 0)))
(let zero (fn (n) (= n 0)))

;; Fibonacci sequence
(rec fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

;; More efficient tail-recursive fibonacci
(rec fibTail (n)
  (rec fibHelper (n a b)
    (if (= n 0)
        a
        (fibHelper (- n 1) b (+ a b))))
  (fibHelper n 0 1))

;; Sum and product of lists
(let sum (fn (xs) (foldLeft + 0 xs)))
(let product (fn (xs) (foldLeft * 1 xs)))

;; Average
(let average (fn (xs)
  (let len (length xs))
  (if (= len 0)
      0
      (/ (sum xs) len))))

;; Clamp value between min and max
(let clamp (fn (minVal maxVal x)
  (max minVal (min maxVal x))))

;; Sign function
(let sign (fn (x)
  (if (< x 0)
      -1
      (if (> x 0)
          1
          0))))
; Simple math functions for testing
(let add (fn (x y) (+ x y)))

(let multiply (fn (x y) (* x y)))

(let factorial 
  (rec fact (n)
    (if (= n 0)
        1
        (* n (fact (- n 1))))))

(let strConcat (fn (a b) (strConcat a b)))

(let length (fn (lst) 
  (match lst
    ((list) 0)
    ((list h ... rest) (+ 1 (length rest))))))

(let sum (fn (lst)
  (match lst
    ((list) 0)
    ((list h ... rest) (+ h (sum rest))))))

; Test edge cases
(let isPositive (fn (n) (> n 0)))
(let isEven (fn (n) (= (% n 2) 0)))
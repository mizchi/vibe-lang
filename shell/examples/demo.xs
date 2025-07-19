# XS Shell Demo

# Basic calculations
42
(+ 1 2)
(* 3 4)

# Define functions
(let double (lambda (x) (* x 2)))
(double 21)

# Lists
(list 1 2 3)
(cons 0 (list 1 2))

# Higher-order functions
(let map (rec map (f xs)
  (match xs
    ((list) (list))
    ((list h t) (cons (f h) (map f t))))))

(map double (list 1 2 3))
((rec map (f xs)
  (match xs
    ((list) (list))
    ((list h t) (cons (f h) (map f t))))) (fn (x) (* x 2)) (list 1 2 3))
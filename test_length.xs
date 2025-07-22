((rec length (xs)
  (match xs
    ((list) 0)
    ((list h t) (+ 1 (length t))))) (list 1 2 3 4 5))
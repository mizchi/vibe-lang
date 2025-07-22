((rec filter (p xs)
  (match xs
    ((list) (list))
    ((list h t) 
      (if (p h)
          (cons h (filter p t))
          (filter p t))))) (fn (x) (> x 2)) (list 1 2 3 4))
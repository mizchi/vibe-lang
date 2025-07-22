((rec reverse (xs)
  ((rec rev-helper (xs acc)
    (match xs
      ((list) acc)
      ((list h t) (rev-helper t (cons h acc))))) xs (list))) (list 1 2 3))
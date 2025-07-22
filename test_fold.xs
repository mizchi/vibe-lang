((rec fold-left (f acc xs)
  (match xs
    ((list) acc)
    ((list h t) (fold-left f (f acc h) t)))) + 0 (list 1 2 3 4))
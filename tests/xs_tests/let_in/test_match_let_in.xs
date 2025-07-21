
(match (list 1 2 3)
  ((list) 0)
  ((list x xs)
    (let head_squared (* x x) in
      head_squared)))

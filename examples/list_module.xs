(module ListUtils
  (export length head tail sum)
  
  (rec length (xs)
    (match xs
      ((list) 0)
      ((list _ rest) (+ 1 (length rest)))))
  
  (let head
    (fn (xs)
      (match xs
        ((list) 0)
        ((list x _) x))))
  
  (let tail
    (fn (xs)
      (match xs
        ((list) (list))
        ((list _ rest) rest))))
  
  (rec sum (xs)
    (match xs
      ((list) 0)
      ((list x rest) (+ x (sum rest))))))
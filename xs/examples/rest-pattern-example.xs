;; Simple rest pattern test

(let result (match (list 1 2 3 4 5)
  ((list x ...tail) tail)) in

(print result))
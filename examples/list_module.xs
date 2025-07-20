(module ListUtils
  (export sum count_positive double_all)
  
  (let sum (rec sum (lst)
    (match lst
      ((list) 0)
      ((list h t) (+ h (sum t))))))
  
  (let count_positive (rec count_positive (lst)
    (match lst
      ((list) 0)
      ((list h t) 
        (if (> h 0)
            (+ 1 (count_positive t))
            (count_positive t))))))
  
  (let double_all (rec double_all (lst)
    (match lst
      ((list) (list))
      ((list h t) (cons (* h 2) (double_all t))))))
)

((rec sum_squares (n)
  (let is_zero (= n 0) in
    (if is_zero
        0
        (let square (* n n) in
          (+ square (sum_squares (- n 1)))))))
 5)

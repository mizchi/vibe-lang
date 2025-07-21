((rec factorial (n)
  (let is_zero (= n 0) in
    (if is_zero
        1
        (* n (factorial (- n 1))))))
 5)
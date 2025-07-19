((rec factorial (n : Int) : Int
  (if (<= n 1)
      1
      (* n (factorial (- n 1))))) 5)
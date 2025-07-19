((rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1)))) 3)
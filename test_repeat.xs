((rec repeat-string (n s)
  (if (= n 0)
      ""
      (concat s (repeat-string (- n 1) s)))) 3 "Hi")
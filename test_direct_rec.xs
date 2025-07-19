; Direct recursive call test
(rec countdown (n)
  (if (= n 0)
      0
      (countdown (- n 1))))
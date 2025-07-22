((rec gcd (a b)
  (if (= b 0)
      a
      (gcd b (% a b)))) 48 18)
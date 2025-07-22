(list 
  ((fn (n) (= (% n 2) 0)) 4)
  ((fn (n) ((fn (b) (if b false true)) ((fn (n) (= (% n 2) 0)) n))) 5))
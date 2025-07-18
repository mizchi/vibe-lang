(let fact (lambda (n : Int) 
  (if (= n 0) 
      1 
      (* n ((fact) (- n 1))))))
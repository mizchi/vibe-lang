(module TestModule
  (export add multiply factorial)
  
  (let add (fn (x y) (+ x y)))
  
  (let multiply (fn (x y) (* x y)))
  
  (let factorial 
    (rec fact (n)
      (if (= n 0)
          1
          (* n (fact (- n 1))))))
)
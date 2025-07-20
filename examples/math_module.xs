(module Math
  (export add subtract multiply divide)
  
  (let add (fn (x y) (+ x y)))
  (let subtract (fn (x y) (- x y)))
  (let multiply (fn (x y) (* x y)))
  (let divide (fn (x y) (/ x y))))
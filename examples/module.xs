(module Math
    (export add sub mul PI)
    
    (define PI 3.14159265359)
    
    (define add (lambda (x y) (+ x y)))
    
    (define sub (lambda (x y) (- x y)))
    
    (define mul (lambda (x y) (* x y))))
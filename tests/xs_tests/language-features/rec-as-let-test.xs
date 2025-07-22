;; Test rec with let binding

(let factorial (rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1))))) in

(print (factorial 5)))
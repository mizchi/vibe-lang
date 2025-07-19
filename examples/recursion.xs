; 再帰関数の例

; rec構文による階乗
((rec factorial (n : Int) : Int
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))
 5)  ; => 120

; フィボナッチ数列
((rec fib (n : Int) : Int
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))
 10) ; => 55
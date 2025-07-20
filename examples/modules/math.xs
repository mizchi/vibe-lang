; 数学モジュール
(module Math
  (export add sub mul div pow abs max min PI E)
  
  ; 定数
  (define PI 3.14159265359)
  (define E 2.71828182846)
  
  ; 基本演算
  (define add (fn (x y) (+ x y)))
  (define sub (fn (x y) (- x y)))
  (define mul (fn (x y) (* x y)))
  (define div (fn (x y) (/ x y)))
  
  ; 累乗 (簡易実装)
  (define pow (fn (base exp)
    (if (= exp 0)
        1
        (* base (pow base (- exp 1))))))
  
  ; 絶対値
  (define abs (fn (x)
    (if (< x 0)
        (- 0 x)
        x)))
  
  ; 最大値
  (define max (fn (x y)
    (if (> x y) x y)))
  
  ; 最小値
  (define min (fn (x y)
    (if (< x y) x y))))
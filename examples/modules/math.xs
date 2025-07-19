; 数学モジュール
(module Math
  (export add sub mul div pow abs max min PI E)
  
  ; 定数
  (define PI 3.14159265359)
  (define E 2.71828182846)
  
  ; 基本演算
  (define add (lambda (x y) (+ x y)))
  (define sub (lambda (x y) (- x y)))
  (define mul (lambda (x y) (* x y)))
  (define div (lambda (x y) (/ x y)))
  
  ; 累乗 (簡易実装)
  (define pow (lambda (base exp)
    (if (= exp 0)
        1
        (* base (pow base (- exp 1))))))
  
  ; 絶対値
  (define abs (lambda (x)
    (if (< x 0)
        (- 0 x)
        x)))
  
  ; 最大値
  (define max (lambda (x y)
    (if (> x y) x y)))
  
  ; 最小値
  (define min (lambda (x y)
    (if (< x y) x y))))
; モジュールシステムの例

; 数学関数モジュール
(module Math
  (export add sub mul div square)
  
  (define add (fn (x y) (+ x y)))
  (define sub (fn (x y) (- x y)))
  (define mul (fn (x y) (* x y)))
  (define div (fn (x y) (/ x y)))
  (define square (fn (x) (* x x))))

; モジュールのインポート
(import (Math add square))

; インポートした関数の使用
(add 10 (square 5))  ; => 35

; 修飾名での使用
Math.div 100 4       ; => 25

; 別名でのインポート
(import Math as M)
(M.mul 7 6)          ; => 42
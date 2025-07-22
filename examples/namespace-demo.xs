; XS言語の名前空間システムのデモ

; Math名前空間に関数を追加
(namespace Math
  (add square (fn (x) (* x x)))
  (add cube (fn (x) (* x x x)))
  (add factorial (rec fact (n)
    (if (= n 0)
        1
        (* n (fact (- n 1)))))))

; Math.utils名前空間に関数を追加
(namespace Math.utils
  (add isPrime (fn (n)
    (if (<= n 1)
        false
        (let checkDivisor (fn (d)
          (if (> (* d d) n)
              true
              (if (= (% n d) 0)
                  false
                  (checkDivisor (+ d 1)))))
          in (checkDivisor 2)))))
  
  (add gcd (rec gcd (a b)
    (if (= b 0)
        a
        (gcd b (% a b))))))

; String.utils名前空間に関数を追加
(namespace String.utils
  (add capitalize (fn (s)
    (if (= (stringLength s) 0)
        s
        (strConcat
          (toUpper (stringAt s 0))
          (stringSlice s 1 (stringLength s))))))
  
  (add reverseString (fn (s)
    (let len (stringLength s) in
      (let revHelper (rec helper (i acc)
        (if (< i 0)
            acc
            (helper (- i 1) (strConcat acc (stringAt s i)))))
        in (revHelper (- len 1) ""))))))

; 名前空間から関数を使用
(namespace Main)

; 個別にインポート
(import Math (square cube factorial))
(import Math.utils (isPrime gcd))
(import String.utils as Str)

(let main (fn ()
  (let n 10 in
    (print (strConcat "Square of " (strConcat (intToString n) 
      (strConcat " is " (intToString (square n))))))
    (print (strConcat "Cube of " (strConcat (intToString n)
      (strConcat " is " (intToString (cube n))))))
    (print (strConcat "Factorial of " (strConcat (intToString n)
      (strConcat " is " (intToString (factorial n))))))
    (print (strConcat "Is " (strConcat (intToString n)
      (strConcat " prime? " (if (isPrime n) "Yes" "No")))))
    (print (strConcat "GCD of 48 and 18 is " (intToString (gcd 48 18))))
    (print (Str.capitalize "hello world"))
    (print (Str.reverseString "hello")))))

; 関数の更新例
(namespace Math
  (update square (fn (x)
    ; より効率的な実装（仮）
    (let result (* x x) in
      (print (strConcat "Squared " (intToString x)))
      result))))

; エイリアスの作成
(alias Math.factorial fact)
(alias Math.utils.isPrime primeCheck)

; 別のモジュールでの使用
(namespace Examples)
(import Math (fact))  ; エイリアスを使用

(let testFactorial (fn ()
  (print (intToString (fact 5)))))  ; 120を出力
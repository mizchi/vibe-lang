; Chapter 1 練習問題の解答例

; 必要なライブラリ関数をインポート
(use lib/String (concat))

; 問題1: 摂氏を華氏に変換する関数
(let celsiusToFahrenheit (fn (c: Float)
  (+ (* c 1.8) 32.0)))

; テスト
; (celsiusToFahrenheit 0.0)   ; 32.0
; (celsiusToFahrenheit 100.0) ; 212.0
; (celsiusToFahrenheit 37.0)  ; 98.6

; 問題2: 数値が偶数かどうかを判定する関数
(let isEven (fn (n: Int)
  (= (% n 2) 0)))

; テスト - 以下のコマンドで実行可能:
; cargo run -p xs-tools --bin xsc -- run examples/chapter1/exercises.xs
; (isEven 4)   ; true
; (isEven 7)   ; false
; (isEven 0)   ; true
; (isEven -2)  ; true

; 問題3: 文字列を指定回数繰り返す関数
(rec repeatString (s: String n: Int)
  (if (= n 0)
      ""
      (concat s (repeatString s (- n 1)))))

; より効率的な末尾再帰版
(let repeatStringTail (fn (s: String n: Int)
  (rec repeatHelper (n acc)
    (if (= n 0)
        acc
        (repeatHelper (- n 1) (concat acc s))))
  (repeatHelper n "")))

; テスト
; (repeatString "Hi" 3)        ; "HiHiHi"
; (repeatString "XS " 2)       ; "XS XS "
; (repeatStringTail "!" 5)     ; "!!!!!"
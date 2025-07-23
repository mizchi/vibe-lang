; 自動再帰検出のテスト

(use lib/String (concat))

; rec なしで再帰関数を定義
(let repeatString (fn (s: String n: Int)
  (if (= n 0)
      ""
      (concat s (repeatString s (- n 1))))))

; 使用例
(repeatString "Hi" 3)
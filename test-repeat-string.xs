; repeatString の正しい実装例

; まず必要なモジュールをインポート
(use lib/String (concat))

; rec キーワードを使って再帰関数を定義
(rec repeatString (s: String n: Int)
  (if (= n 0)
      ""
      (concat s (repeatString s (- n 1)))))

; テスト
(repeatString "Hi" 3)    ; => "HiHiHi"
(repeatString "X" 5)     ; => "XXXXX"
(repeatString "abc" 0)   ; => ""

;; XS Standard Library - String Operations
;; 文字列操作のための関数群
;; Note: 現在の実装では基本的な文字列操作のみ

;; String predicates
(let emptyString (fn (s) (= s "")))

;; String concatenation (using built-in concat)
(let strAppend concat)

;; Join strings with separator
(rec join (sep strs)
  (match strs
    ((list) "")
    ((list s) s)
    ((list h t) (concat h (concat sep (join sep t))))))

;; Repeat string n times
(rec repeatString (n s)
  (if (= n 0)
      ""
      (concat s (repeatString (- n 1) s))))

;; String comparison helpers
(let strEq (fn (s1 s2) (= s1 s2)))
(let strNeq (fn (s1 s2) (not (= s1 s2))))
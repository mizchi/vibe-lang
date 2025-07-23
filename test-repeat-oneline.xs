(use lib/String (concat))
(rec repeatString (s: String n: Int) (if (= n 0) "" (concat s (repeatString s (- n 1)))))
(repeatString "Hi" 3)
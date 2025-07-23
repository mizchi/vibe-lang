(module RepeatTest
  (use lib/String (concat))
  
  (rec repeatString (s: String n: Int)
    (if (= n 0)
        ""
        (concat s (repeatString s (- n 1)))))
  
  (let test1 (repeatString "Hi" 3))
  (let test2 (repeatString "X" 5))
  (let test3 (repeatString "abc" 0)))
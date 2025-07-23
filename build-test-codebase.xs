; Script to build a test codebase with individual functions
; This will be used to generate an XBin file with multiple function definitions

(let codebase (codebase-new))

; Add basic math functions
(codebase-add-term codebase "add" (fn (x y) (+ x y)) (-> Int (-> Int Int)))
(codebase-add-term codebase "multiply" (fn (x y) (* x y)) (-> Int (-> Int Int)))
(codebase-add-term codebase "square" (fn (x) (* x x)) (-> Int Int))
(codebase-add-term codebase "isPositive" (fn (n) (> n 0)) (-> Int Bool))
(codebase-add-term codebase "isEven" (fn (n) (= (% n 2) 0)) (-> Int Bool))

; Add string functions
(codebase-add-term codebase "strLen" (fn (s) (strLength s)) (-> String Int))
(codebase-add-term codebase "strEmpty" (fn (s) (= (strLength s) 0)) (-> String Bool))

; Add list functions
(codebase-add-term codebase "listLength" 
  (rec length (lst)
    (match lst
      ((list) 0)
      ((list h ... rest) (+ 1 (length rest)))))
  (-> (List a) Int))

; Save the codebase
(codebase-save codebase "test-multi-functions.xbin")
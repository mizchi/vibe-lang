; Test isEven function
(let isEven (fn (n) (= (% n 2) 0)))

; Create a list of test results
(list
  (isEven 4)    ; true
  (isEven 7)    ; false
  (isEven 0)    ; true
  (isEven -2)   ; true
)
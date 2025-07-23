; Test modulo operator
(let isEven (fn (n)
  (= (% n 2) 0)))

; Test the function
(let result4 (isEven 4))
(let result7 (isEven 7))
(let result0 (isEven 0))
(let result2 (isEven -2))

; Return test results as a list
(list result4 result7 result0 result2)
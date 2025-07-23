; Test String.concat functionality

; Define repeatString function using String.concat
(rec repeatString (s: String n: Int)
  (if (= n 0)
      ""
      (String.concat s (repeatString s (- n 1)))))

; Test cases
(print (repeatString "Hi" 3))       ; Should print: HiHiHi
(print (repeatString "XS " 2))      ; Should print: XS XS 
(print (repeatString "!" 5))        ; Should print: !!!!!
(print (repeatString "test" 0))     ; Should print: (empty string)
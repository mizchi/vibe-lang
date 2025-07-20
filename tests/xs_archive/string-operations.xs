; Test string operations

; Test str-concat
(let test-concat (str-concat "Hello, " "World!"))
(print test-concat)  ; Should print: Hello, World!

; Test int-to-string
(let test-int-to-str (int-to-string 42))
(print test-int-to-str)  ; Should print: 42

; Test string-to-int
(let test-str-to-int (string-to-int "123"))
(print test-str-to-int)  ; Should print: 123

; Test string-length
(let test-length (string-length "Hello"))
(print test-length)  ; Should print: 5

; Combined test - build a message with count
(let count 10)
(let message (str-concat "Count: " (int-to-string count)))
(print message)  ; Should print: Count: 10

; Test with dynamic content
(let build-message (fn (name value)
  (str-concat (str-concat name ": ") (int-to-string value))))

(print (build-message "Score" 100))  ; Should print: Score: 100
(print (build-message "Level" 5))    ; Should print: Level: 5
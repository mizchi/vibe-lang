-- Test string operations

-- Test str-concat
let testConcat = String.concat "Hello, " "World!" in
let dummy1 = IO.print testConcat in  -- Should print: Hello, World!

-- Test int-to-string
let testIntToStr = Int.toString 42 in
let dummy2 = IO.print testIntToStr in  -- Should print: 42

-- Test string-to-int
let testStrToInt = String.toInt "123" in
let dummy3 = IO.print testStrToInt in  -- Should print: 123

-- Test string-length
let testLength = String.length "Hello" in
let dummy4 = IO.print testLength in  -- Should print: 5

-- Combined test - build a message with count
let count = 10 in
let message = String.concat "Count: " (Int.toString count) in
let dummy5 = IO.print message in  -- Should print: Count: 10

-- Test with dynamic content
let buildMessage name value =
  String.concat (String.concat name ": ") (Int.toString value) in

let dummy6 = IO.print (buildMessage "Score" 100) in  -- Should print: Score: 100
IO.print (buildMessage "Level" 5)    -- Should print: Level: 5
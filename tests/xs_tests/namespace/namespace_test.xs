-- Test builtin module namespaces

-- Test Int module
IO.print (Int.toString 42)
IO.print (Int.add 10 20)

-- Test String module  
IO.print (String.concat "Hello, " "World!")
IO.print (String.length "Hello")
IO.print (String.fromInt 123)

-- Test mixed usage
IO.print (String.concat "Answer: " (Int.toString 42))
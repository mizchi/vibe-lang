-- New Function Definition Syntax Demo
-- This file demonstrates the new function definition syntax introduced in XS

-- Basic function with type annotations
let add x:Int y:Int -> Int = x + y

-- Function with optional parameters
let greet name:String title?:String? -> String =
  match title {
    None -> strConcat "Hello, " name
    Some t -> strConcat "Hello, " (strConcat t (strConcat " " name))
  }

-- Using the Option type sugar syntax
let safeDiv x:Int y:Int? -> Int? =
  match y {
    None -> None
    Some 0 -> None
    Some n -> Some (x / n)
  }

-- Function with effects
let readAndProcess path:String transform?:(String -> String)? -> <IO> String =
  let contents = perform IO.readFile path in
  match transform {
    None -> contents
    Some f -> f contents
  }

-- Recursive function with new syntax
let fibonacci = rec fib n:Int -> Int =
  if n < 2 {
    n
  } else {
    (fib (n - 1)) + (fib (n - 2))
  }

-- Partial application with optional parameters
let makeLogger prefix:String debug?:Bool? -> (String -> <IO> Unit) =
  fn msg ->
    match debug {
      None -> perform IO.print (strConcat prefix msg)
      Some true -> perform IO.print (strConcat "[DEBUG] " (strConcat prefix msg))
      Some false -> perform IO.print (strConcat prefix msg)
    }

-- Example usage
let main () = do
  -- Basic addition
  let result = add 5 3
  perform IO.print (intToString result)
  
  -- Greeting with and without title
  perform IO.print (greet "Alice" None)
  perform IO.print (greet "Bob" (Some "Dr."))
  
  -- Safe division
  match safeDiv 10 (Some 2) {
    None -> perform IO.print "Division failed"
    Some n -> perform IO.print (intToString n)
  }
  
  -- Create specialized loggers
  let infoLog = makeLogger "[INFO] " None
  let debugLog = makeLogger "[APP] " (Some true)
  
  infoLog "Application started"
  debugLog "Debug mode enabled"
end
-- Test new function definition syntax

-- Basic function with type annotations
let add x:Int y:Int -> Int = x + y

-- Function with effects
let readFile path:String -> <IO> String = 
  perform IO (readFileContents path)

-- Function with multiple effects
let processData x:Int -> <IO, Error> Int = {
  if x < 0 {
    perform Error "Negative number"
  } else {
    perform IO (print "Processing...")
    x * 2
  }
}

-- Test calling the functions
add 5 3
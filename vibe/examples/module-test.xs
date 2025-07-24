-- Test module definition and import

-- Define a simple Math module
module Math {
  export add, multiply, PI
  
  -- Constants
  let PI = 3.14159
  
  -- Functions
  let add x y = x + y
  let multiply x y = x * y
  
  -- Internal helper (not exported)
  let square x = x * x
}

-- Import specific items
import Math

-- Use imported functions
let result1 = Math.add 5 3 in
let result2 = Math.PI * 2 in

-- Test results
let dummy1 = IO.print "5 + 3 =" in
let dummy2 = IO.print result1 in
let dummy3 = IO.print "PI * 2 =" in
let dummy4 = IO.print result2 in

IO.print "Module test completed!"
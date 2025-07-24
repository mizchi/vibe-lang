-- Simple test for optional parameters

-- Basic optional parameter test
let testOpt x?:Int -> Int = 
  match x {
    None -> 0
    Some val -> val
  }

-- Test without argument
-- testOpt None
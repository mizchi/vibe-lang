-- Simple test for Option type

-- Option type definition
type Option a = None | Some a

-- Simple function using Option
let getValue opt:Option Int -> Int =
  match opt {
    None -> 0
    Some x -> x
  }

-- Test
let result = getValue (Some 42)
-- Advanced test for partial application with optional parameters

-- Option type definition
type Option a = None | Some a

-- Function with mixed parameters
let process required1:Int required2:String optional1?:Int optional2?:String -> String =
  String.concat required2 (Int.toString required1)

-- Test different partial application scenarios

-- 1. Apply only first required parameter
let p1 = process 42
-- p1 : String -> Int? -> String? -> String

-- 2. Apply both required parameters
let p2 = process 42 "hello"
-- p2 : Int? -> String? -> String

-- 3. Apply required + first optional
let p3 = process 42 "hello" (Some 99)
-- p3 : String? -> String

-- 4. Apply all parameters at once
let p4 = process 42 "hello" (Some 99) (Some "world")
-- p4 : String

-- Test usage
let r1 = p1 "test" None None
let r2 = p2 None None
let r3 = p3 None
let r4 = p4
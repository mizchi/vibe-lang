-- Test parameter ordering validation

-- Valid: all required parameters come first
let validFunc1 x:Int y:String z?:Bool -> Int = 42

-- Valid: multiple optional parameters at the end
let validFunc2 a:Int b?:String c?:Bool -> Int = 42

-- Valid: all parameters are optional
let validFunc3 a?:Int b?:String -> Int = 42

-- Invalid: optional parameter before required parameter
-- This should produce an error
-- let invalidFunc x?:Int y:String -> Int = 42
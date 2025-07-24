-- Test parameter ordering validation - error cases

-- Invalid: optional parameter in the middle
let invalidFunc1 x:Int y?:String z:Bool -> Int = 42
-- Test partial application with optional parameters (type checking only)

-- Option type definition
type Option a = None | Some a

-- Function with optional parameters
let config port:Int host?:String debug?:Bool -> String =
  String.concat "config" (Int.toString port)

-- Test 1: Partial application with only required parameter
let configLocal = config 8080

-- Test 2: Apply the partially applied function
let result1 = configLocal None None
let result2 = configLocal (Some "example.com") (Some true)

-- Test 3: Partial application with some optional parameters
let configWithHost = config 8080 (Some "localhost")
let result3 = configWithHost None
let result4 = configWithHost (Some false)
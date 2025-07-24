-- Test partial application with optional parameters

-- Option type definition
type Option a = None | Some a

-- Function with optional parameters
let config port:Int host?:String debug?:Bool -> String =
  let hostStr = match host {
    None -> "localhost"
    Some h -> h
  } in
  let debugStr = match debug {
    None -> "false"
    Some true -> "true"
    Some false -> "false"
  } in
    String.concat hostStr (String.concat ":" (Int.toString port))

-- Test 1: Partial application with only required parameter
let configLocal = config 8080

-- Test 2: What type does configLocal have?
-- It should be: String? -> Bool? -> String
-- or maybe: (Option String) -> (Option Bool) -> String

-- Test 3: Apply the partially applied function
let result1 = configLocal None None
let result2 = configLocal (Some "example.com") (Some true)
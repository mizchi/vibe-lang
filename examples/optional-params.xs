-- Test optional keyword arguments

-- Option type definition
type Option a = None | Some a

-- Function with optional parameter
let run key:Int flag?:String -> Int = 
  match flag {
    None -> key
    Some f -> key + (String.length f)
  }

-- Function with multiple optional parameters
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
    String.concat hostStr (String.concat ":" (String.concat (Int.toString port) (String.concat " debug=" debugStr)))

-- Test calling with all arguments
let test1 = run 42 (Some "verbose")

-- Test calling without optional argument (requires explicit None for now)
let test2 = run 42 None

-- Test multiple optionals
let test3 = config 8080 (Some "example.com") (Some true)
let test4 = config 3000 None None
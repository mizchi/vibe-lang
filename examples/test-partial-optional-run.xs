-- Test partial application with optional parameters (runtime)

-- Option type definition
type Option a = None | Some a

-- Simple function with optional parameter
let greet name:String title?:String -> String =
  match title {
    None -> String.concat "Hello, " name
    Some t -> String.concat "Hello, " (String.concat t (String.concat " " name))
  }

-- Test partial application
let greetCasual = greet "Alice"

-- Apply with None
print (greetCasual None)

-- Apply with Some
print (greetCasual (Some "Dr"))
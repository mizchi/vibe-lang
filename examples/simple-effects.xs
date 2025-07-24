-- Simple effect examples to test the system

-- Basic IO effect
let hello = fn unit -> perform IO "Hello, World!"

-- State effect
let getCounter = fn unit -> perform State ()

-- Exception effect  
let divide = fn x y ->
  if y == 0 {
    perform Exception "Division by zero"
  } else {
    x / y
  }

-- Simple pure function
let add = fn x y -> x + y

-- Function with multiple effects
let complexFunction = fn x ->
  let tmp = perform IO "Starting computation" in
  let state = perform State () in
  if state > 0 {
    perform Exception "State is positive"
  } else {
    x + state
  }
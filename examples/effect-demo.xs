-- Effect System Demo
-- This file demonstrates the extensible effects system in XS

-- Basic IO effect
printHello : () -> IO Unit
printHello () = perform IO.print "Hello, Effects!"

-- State effect with polymorphic state
increment : () -> State<Int> Unit  
increment () = do
  x <- perform State.get
  perform State.put (x + 1)

-- Multiple effects
readAndPrint : () -> {IO, Exception<String>} Unit
readAndPrint () = do
  input <- perform IO.read
  if input == "" {
    perform Exception.throw "Empty input!"
  } else {
    perform IO.print input
  }

-- Effect handlers
runState : forall a s. s -> (() -> State<s> a) -> a
runState initial computation = 
  handle computation () with
    | State.get () resume -> resume initial initial
    | State.put newState resume -> resume () newState
    | return x state -> x
  end

-- Higher-order effects (effect that uses other effects)  
loggedIncrement : () -> {State<Int>, IO} Unit
loggedIncrement () = do
  perform IO.print "Incrementing state..."
  increment ()
  x <- perform State.get
  perform IO.print ("New value: " ++ Int.toString x)

-- Effect polymorphism
map : forall a b e. (a -> e b) -> [a] -> e [b]
map f lst = match lst {
  [] -> return []
  h :: t -> do
    h' <- f h
    t' <- map f t
    return (h' :: t')
}

-- Example: Map with IO effect
printNumbers : [Int] -> IO Unit
printNumbers nums = do
  map (fn n -> perform IO.print (Int.toString n)) nums
  return ()

-- Async effect example
fetchData : String -> Async String
fetchData url = perform Async.await (
  perform Async.async (fn () -> 
    -- Simulated async operation
    "Data from " ++ url
  )
)

-- Combining async with error handling
safeFetech : String -> {Async, Exception<String>} String
safeFetch url = 
  if url == "" {
    perform Exception.throw "Invalid URL"
  } else {
    fetchData url
  }

-- Main example combining multiple effects
main : () -> IO Unit
main () = do
  perform IO.print "=== Effect System Demo ==="
  
  -- Run stateful computation
  let result = runState 0 (fn () -> do
    increment ()
    increment ()
    perform State.get
  )
  
  perform IO.print ("Final state: " ++ Int.toString result)
  
  -- Handle exceptions
  handle readAndPrint () with
    | Exception.throw msg resume -> 
        perform IO.print ("Error caught: " ++ msg)
    | return x -> x
  end
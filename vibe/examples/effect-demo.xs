-- XS Language Effect System Demo
-- This file demonstrates the effect system for tracking side effects

-- Pure functions have no effects
let add = fn x y -> x + y
let double = fn x -> x * 2

-- Effectful functions are marked with effects
-- IO effect for printing
let printLine = fn str -> 
  perform IO (print str)

-- Function with IO effect
let greet = fn name ->
  printLine (strConcat "Hello, " name)

-- Composite effects
let readAndPrint = fn () ->
  let input = perform IO readLine in
  perform IO (print input)

-- Effect handlers
withHandler IO
  (fn op cont ->
    match op {
      print str -> 
        builtinPrint str
        cont unit
      readLine -> 
        cont (builtinReadLine)
      _ -> error "Unknown IO operation"
    })
  -- Body
  (greet "World")

-- Pure computation with local state effect
withHandler State
  (fn op cont ->
    match op {
      get -> cont currentState
      put newState -> 
        setCurrentState newState
        cont unit
      _ -> error "Unknown State operation"
    })
  -- Body - counter example
  (let counter = perform State get in
    perform State (put (counter + 1))
    perform State get)

-- Function types with effects
-- add : Int -> Int -> Int                    -- Pure
-- printLine : String -> {IO} Unit            -- IO effect
-- readAndPrint : () -> {IO} Unit             -- IO effect
-- counter : {State} Int                      -- State effect

-- Effect polymorphism
let map {e} = fn f lst ->
  match lst {
    [] -> []
    h :: t -> cons (f h) (map f t)
  }
-- map : {e} (a -> {e} b) -> List a -> {e} List b

-- Multiple effects
let logAndIncrement = fn x ->
  perform IO (print (intToString x))
  x + 1
-- logAndIncrement : Int -> {IO} Int

-- Effect inference example
let processNumbers = fn nums ->
  map logAndIncrement nums
-- processNumbers : List Int -> {IO} List Int
-- Debug example: Function composition
-- compose :: (b -> c) -> (a -> b) -> (a -> c)
let compose = fn f = fn g = fn x = f (g x) in

-- inc :: Int -> Int  
let inc = fn x = x + 1 in

-- double :: Int -> Int
let double = fn x = x * 2 in

-- Test composition
let incThenDouble = compose double inc in
let doubleThenInc = compose inc double in

-- Debug traces
let result1 = incThenDouble 5 in  -- (5 + 1) * 2 = 12
let result2 = doubleThenInc 5 in  -- (5 * 2) + 1 = 11

{ 
  incThenDouble: result1,
  doubleThenInc: result2 
}
EOF < /dev/null
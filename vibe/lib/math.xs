-- XS Standard Library - Math Operations
-- 数学関数と数値演算

-- Basic math operations
let neg x = 0 - x
let reciprocal x = 1.0 /. x

-- Exponentiation
rec pow base exp = 
  if exp = 0 { 1 }
  else if exp < 0 { 1 / pow base (neg exp) }
  else { base * pow base (exp - 1) }

-- Factorial
rec factorial n = 
  if n = 0 { 1 }
  else { n * factorial (n - 1) }

-- GCD and LCM
rec gcd a b = 
  if b = 0 { a }
  else { gcd b (a % b) }

let lcm a b = (a * b) / gcd a b

-- Number predicates
let even n = n % 2 = 0
let odd n = not (even n)
let positive n = n > 0
let negative n = n < 0
let zero n = n = 0

-- Fibonacci sequence
rec fib n = 
  if n < 2 { n }
  else { fib (n - 1) + fib (n - 2) }

-- More efficient tail-recursive fibonacci
rec fibTail n = {
  rec fibHelper n a b = 
    if n = 0 { a }
    else { fibHelper (n - 1) b (a + b) };
  fibHelper n 0 1
}

-- Sum and product of lists
let sum xs = foldLeft (\acc x -> acc + x) 0 xs
let product xs = foldLeft (\acc x -> acc * x) 1 xs

-- Average
let average xs = 
  let len = length xs in
  if len = 0 { 0 }
  else { sum xs / len }

-- Clamp value between min and max
let clamp minVal maxVal x = max minVal (min maxVal x)

-- Sign function
let sign x = 
  if x < 0 { -1 }
  else if x > 0 { 1 }
  else { 0 }
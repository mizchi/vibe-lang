-- XS Standard Library - Core Functions
-- 基本的な関数と演算子のラッパー

-- Function composition
let compose f g = \x -> f (g x)

-- Identity function
let id x = x

-- Constant function
let const x = \y -> x

-- Flip function arguments
let flip f = \x y -> f y x

-- Tuple operations
let fst pair = case pair of {
  [x, y] -> x
}

let snd pair = case pair of {
  [x, y] -> y
}

-- Maybe type helpers
type Maybe a = Just a | Nothing

let maybe default f m = case m of {
  Just x -> f x;
  Nothing -> default
}

-- Either type helpers
type Either a b = Left a | Right b

let either f g e = case e of {
  Left x -> f x;
  Right y -> g y
}

-- Boolean operations
let not b = if b { false } else { true }
let and a b = if a { b } else { false }
let or a b = if a { true } else { b }

-- Numeric operations
let inc n = n + 1
let dec n = n - 1
let double n = n * 2
let square n = n * n
let abs n = if n < 0 { 0 - n } else { n }

-- Comparison helpers
let min a b = if a < b { a } else { b }
let max a b = if a > b { a } else { b }

-- Function application helpers
let apply f x = f x
let pipe x f = f x
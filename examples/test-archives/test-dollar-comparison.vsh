# Direct comparison: $ operator vs parentheses

let f x = x + 1
let g x = x * 2

# These two should produce the same result:
f $ g 3      # f (g 3) = f 6 = 7
f (g 3)      # f (g 3) = f 6 = 7
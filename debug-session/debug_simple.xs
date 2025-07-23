let compose = fn f = fn g = fn x = f (g x) in
let inc = fn x = x + 1 in
let double = fn x = x * 2 in
let test = compose double inc in
test 5
EOF < /dev/null
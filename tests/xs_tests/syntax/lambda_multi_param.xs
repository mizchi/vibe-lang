-- Test multi-parameter lambda expression  
-- expect: 23
let f = fn x = fn y = fn z = x * y + z in f 2 10 3
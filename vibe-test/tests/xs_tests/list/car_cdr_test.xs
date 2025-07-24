-- Test car, cdr, null? functions
-- expect: true

-- Helper functions
let not x = if x { false } else { true } in
let and a b = if a { b } else { false } in

-- Test car (head)
let lst1 = [1, 2, 3] in
let head1 = List.car lst1 in

-- Test cdr (tail)
let tail1 = List.cdr lst1 in

-- Test null?
let empty = [] in
let nonEmpty = [1] in

-- Check results
let test1 = eq head1 1 in
let test2 = eq (List.car tail1) 2 in
let test3 = List.null empty in
let test4 = not (List.null nonEmpty) in

-- All tests must pass
and test1 (and test2 (and test3 test4))
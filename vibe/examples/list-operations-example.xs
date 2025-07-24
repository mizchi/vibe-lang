-- Test list-extras functions

-- Define reverse function
let reverseHelper = rec reverseHelper lst acc ->
  if List.null lst { acc }
  else { reverseHelper (List.cdr lst) (cons (List.car lst) acc) } in

let reverse lst = reverseHelper lst [] in

-- Define append function
let append = rec append xs ys ->
  if List.null xs { ys }
  else { cons (List.car xs) (append (List.cdr xs) ys) } in

-- Define take function
let take = rec take n lst ->
  if n = 0 { [] }
  else if List.null lst { [] }
  else { cons (List.car lst) (take (n - 1) (List.cdr lst)) } in

-- Define drop function
let drop = rec drop n lst ->
  if n = 0 { lst }
  else if List.null lst { [] }
  else { drop (n - 1) (List.cdr lst) } in

-- Test data
let lst1 = [1, 2, 3, 4, 5] in
let lst2 = [6, 7, 8] in

-- Tests
let dummy1 = IO.print "\n=== List Extras Test ===" in

-- Test reverse
let rev = reverse lst1 in
let dummy2 = IO.print "reverse [1,2,3,4,5]:" in
let dummy3 = IO.print rev in

-- Test append
let app = append lst1 lst2 in
let dummy4 = IO.print "\nappend [1,2,3,4,5] [6,7,8]:" in
let dummy5 = IO.print app in

-- Test take
let tk = take 3 lst1 in
let dummy6 = IO.print "\ntake 3 [1,2,3,4,5]:" in
let dummy7 = IO.print tk in

-- Test drop
let dr = drop 2 lst1 in
let dummy8 = IO.print "\ndrop 2 [1,2,3,4,5]:" in
let dummy9 = IO.print dr in

-- Test edge cases
let dummy10 = IO.print "\n--- Edge Cases ---" in
let dummy11 = IO.print "reverse []:" in
let dummy12 = IO.print (reverse []) in
let dummy13 = IO.print "take 10 [1,2,3]:" in
let dummy14 = IO.print (take 10 [1, 2, 3]) in
let dummy15 = IO.print "drop 10 [1,2,3]:" in
let dummy16 = IO.print (drop 10 [1, 2, 3]) in

IO.print "\nAll tests completed!"
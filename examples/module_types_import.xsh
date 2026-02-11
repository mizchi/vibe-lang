// Import exported types
use ./module_types_export.xsh { Color, Maybe, IntPair, make_pair, is_red }let my_color = Red
let my_maybe = Just(100)

test "imported Color" {
  assert(is_red(my_color))
  assert(not(is_red(Green)))
}

test "imported Maybe" {
  let result = match my_maybe { Just(v) => v, Nothing => 0 }
  assert(eq(result, 100))
}

test "imported IntPair" {
  let p = make_pair(5, 7)
  let (a, b) = p
  assert(eq(a + b, 12))
}

import {
  cmp_eq,
  ord_clamp,
  num_add,
  num_sub,
  num_mul,
  num_div,
  num_abs,
  ord_between,
  num_square,
  to_string
} from "./builtin_traits.xsh"

trait Eq
trait Ord
trait Add
trait Sub
trait Mul
trait Div
trait Signed

impl Eq for Int
impl Eq for Float
impl Eq for Double
impl Eq for Bool
impl Eq for String

impl Ord for Int
impl Ord for Float
impl Ord for Double
impl Ord for String

impl Add for Int
impl Add for Float
impl Add for Double
impl Sub for Int
impl Sub for Float
impl Sub for Double
impl Mul for Int
impl Mul for Float
impl Mul for Double
impl Div for Int
impl Div for Float
impl Div for Double
impl Signed for Int
impl Signed for Float
impl Signed for Double

test "cmp_eq generic" {
  assert(cmp_eq(1, 1))
  assert(not(cmp_eq(1, 2)))
}

test "ord_clamp generic" {
  assert(eq(ord_clamp(5, 0, 10), 5))
  assert(eq(ord_clamp(-1, 0, 10), 0))
  assert(eq(ord_clamp(11, 0, 10), 10))
}

test "num_ops generic" {
  assert(eq(num_add(2, 3), 5))
  assert(eq(num_sub(8, 3), 5))
  assert(eq(num_mul(4, 5), 20))
  assert(eq(num_div(20, 4), 5))
}

test "num_abs generic" {
  assert(eq(num_abs(-5), 5))
  assert(eq(num_abs(0), 0))
  assert(eq(num_abs(5), 5))
}

test "ord_between generic" {
  assert(ord_between(2, 1, 3))
  assert(not(ord_between(0, 1, 3)))
}

test "num_square generic" {
  assert(eq(num_square(5), 25))
}

test "to_string generic" {
  assert(string_equals(to_string(42), "42"))
  assert(string_equals(to_string(true), "true"))
}

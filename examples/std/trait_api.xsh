// Trait-oriented core API for std modules.

trait Eq
trait Ord
trait Show
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

impl Show for Int
impl Show for Float
impl Show for Double
impl Show for Bool
impl Show for String

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

let cmp_eq = [T: Eq](a: T, b: T) -> Bool {
  a == b
}

let cmp_ne = [T: Eq](a: T, b: T) -> Bool {
  not(cmp_eq(a, b))
}

let ord_min = [T: Ord](a: T, b: T) -> T {
  if a < b { a } else { b }
}

let ord_max = [T: Ord](a: T, b: T) -> T {
  if a > b { a } else { b }
}

let ord_clamp = [T: Ord](x: T, min_val: T, max_val: T) -> T {
  if x < min_val { min_val }
  else if x > max_val { max_val }
  else { x }
}

let ord_between = [T: Ord](x: T, min_val: T, max_val: T) -> Bool {
  x >= min_val && x <= max_val
}

let num_add = [T: Add](a: T, b: T) -> T {
  a + b
}

let num_sub = [T: Sub](a: T, b: T) -> T {
  a - b
}

let num_mul = [T: Mul](a: T, b: T) -> T {
  a * b
}

let num_div = [T: Div](a: T, b: T) -> T {
  a / b
}

let num_abs = [T: Signed + Ord + Sub](x: T) -> T {
  if x < 0 { 0 - x } else { x }
}

let num_square = [T: Mul](x: T) -> T {
  x * x
}

let num_clamp = [T: Ord](x: T, min_val: T, max_val: T) -> T {
  ord_clamp(x, min_val, max_val)
}

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

export {
  Eq, Ord, Show, Add, Sub, Mul, Div, Signed,
  cmp_eq, cmp_ne,
  ord_min, ord_max, ord_clamp, ord_between,
  num_add, num_sub, num_mul, num_div, num_abs, num_square, num_clamp
}

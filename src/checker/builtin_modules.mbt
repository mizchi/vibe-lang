///|
/// Auto-generated builtin module sources for prelude injection.
/// Do not edit manually. Regenerate with: scripts/gen_builtin_embed.sh

///|
let builtin_builtin_traits_source : String =
  #|
  #|export trait Eq
  #|export trait Hash
  #|export trait Ord
  #|export trait Add
  #|export trait Sub
  #|export trait Mul
  #|export trait Div
  #|export trait Signed
  #|impl Eq for Int
  #|impl Eq for Float
  #|impl Eq for Double
  #|impl Eq for Bool
  #|impl Eq for Char
  #|impl Eq for String
  #|impl Hash for Int
  #|impl Hash for Float
  #|impl Hash for Double
  #|impl Hash for Bool
  #|impl Hash for Char
  #|impl Hash for String
  #|impl Ord for Int
  #|impl Ord for Float
  #|impl Ord for Double
  #|impl Ord for String
  #|impl Add for Int
  #|impl Add for Float
  #|impl Add for Double
  #|impl Sub for Int
  #|impl Sub for Float
  #|impl Sub for Double
  #|impl Mul for Int
  #|impl Mul for Float
  #|impl Mul for Double
  #|impl Div for Int
  #|impl Div for Float
  #|impl Div for Double
  #|impl Signed for Int
  #|impl Signed for Float
  #|impl Signed for Double
  #|export let cmp_eq = [T: Eq](a: T, b: T) -> Bool {
  #|  a == b
  #|}
  #|export let cmp_ne = [T: Eq](a: T, b: T) -> Bool {
  #|  not(cmp_eq(a, b))
  #|}
  #|export let num_abs = [T: Signed + Ord + Sub](x: T) -> T {
  #|  if x < 0 {
  #|    0 - x
  #|  } else {
  #|    x
  #|  }
  #|}
  #|export let num_add = [T: Add](a: T, b: T) -> T {
  #|  a + b
  #|}
  #|export let num_div = [T: Div](a: T, b: T) -> T {
  #|  a / b
  #|}
  #|export let num_mul = [T: Mul](a: T, b: T) -> T {
  #|  a * b
  #|}
  #|export let num_sub = [T: Sub](a: T, b: T) -> T {
  #|  a - b
  #|}
  #|export let ord_max = [T: Ord](a: T, b: T) -> T {
  #|  if a > b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let ord_min = [T: Ord](a: T, b: T) -> T {
  #|  if a < b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let ord_clamp = [T: Ord](x: T, min_val: T, max_val: T) -> T {
  #|  if x < min_val {
  #|    min_val
  #|  }
  #|  else if x > max_val {
  #|    max_val
  #|  }
  #|  else {
  #|    x
  #|  }
  #|}
  #|export let num_clamp = [T: Ord](x: T, min_val: T, max_val: T) -> T {
  #|  ord_clamp(x, min_val, max_val)
  #|}
  #|export let to_string = [T: Show](x: T) -> String {
  #|  __to_string(x)
  #|}
  #|export let num_square = [T: Mul](x: T) -> T {
  #|  x * x
  #|}
  #|export let ord_between = [T: Ord + Eq](x: T, min_val: T, max_val: T) -> Bool {
  #|  x >= min_val && x <= max_val
  #|}
  #|export let hash_require = [T: Hash](x: T) -> T {
  #|  x
  #|}

///|
let builtin_option_source : String =
  #|
  #|export trait Eq
  #|impl Eq for Int
  #|impl Eq for Float
  #|impl Eq for Double
  #|impl Eq for Bool
  #|impl Eq for String
  #|impl [T: Eq] Eq for Option[T]
  #|export let or = [T](a: Option[T], b: Option[T]) -> Option[T] {
  #|  match a {
  #|    Some(_) => a,
  #|    _ => b
  #|  }
  #|}
  #|export let and = [A, B](a: Option[A], b: Option[B]) -> Option[B] {
  #|  match a {
  #|    Some(_) => b,
  #|    _ => None
  #|  }
  #|}
  #|export let zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  #|  match (a, b) {
  #|    (Some(x), Some(y)) => Some((x, y)),
  #|    _ => None
  #|  }
  #|}
  #|export let equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool {
  #|  match (a, b) {
  #|    (Some(x), Some(y)) => x == y,
  #|    (None, None) => true,
  #|    _ => false
  #|  }
  #|}
  #|export let filter = [T](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  #|  match opt {
  #|    Some(v) => if pred(v) {
  #|      Some(v)
  #|    } else {
  #|      None
  #|    },
  #|    _ => None
  #|  }
  #|}
  #|export let map_or = [A, B](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  #|  match opt {
  #|    Some(v) => f(v),
  #|    _ => default
  #|  }
  #|}
  #|export let flatmap = [A, B](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  #|  match opt {
  #|    Some(v) => f(v),
  #|    _ => None
  #|  }
  #|}
  #|export let flatten = [T](opt: Option[Option[T]]) -> Option[T] {
  #|  match opt {
  #|    Some(inner) => inner,
  #|    _ => None
  #|  }
  #|}
  #|export let is_some = [T](opt: Option[T]) -> Bool {
  #|  match opt {
  #|    Some(_) => true,
  #|    _ => false
  #|  }
  #|}
  #|export let is_none = [T](opt: Option[T]) -> Bool {
  #|  not(is_some(opt))
  #|}
  #|export let map_opt = [A, B](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  #|  match opt {
  #|    Some(v) => Some(f(v)),
  #|    _ => None
  #|  }
  #|}
  #|export let or_else = [T](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  #|  match a {
  #|    Some(_) => a,
  #|    _ => fallback()
  #|  }
  #|}
  #|export let zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  #|  match zip(a, b) {
  #|    Some((x, y)) => Some(x + y),
  #|    _ => None
  #|  }
  #|}
  #|export let unwrap_or = [T](opt: Option[T], default: T) -> T {
  #|  match opt {
  #|    Some(v) => v,
  #|    _ => default
  #|  }
  #|}
  #|export let unwrap_or_else = [T](opt: Option[T], fallback: () -> T) -> T {
  #|  match opt {
  #|    Some(v) => v,
  #|    _ => fallback()
  #|  }
  #|}
  #|export let Option::or = [T](a: Option[T], b: Option[T]) -> Option[T] {
  #|  or(a, b)
  #|}
  #|export let Option::and = [A, B](a: Option[A], b: Option[B]) -> Option[B] {
  #|  and(a, b)
  #|}
  #|export let Option::zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  #|  zip(a, b)
  #|}
  #|export let Option::equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool {
  #|  equals(a, b)
  #|}
  #|export let Option::filter = [T](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  #|  filter(opt, pred)
  #|}
  #|export let Option::map_or = [A, B](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  #|  map_or(opt, default, f)
  #|}
  #|export let Option::flatmap = [A, B](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  #|  flatmap(opt, f)
  #|}
  #|export let Option::flatten = [T](opt: Option[Option[T]]) -> Option[T] {
  #|  flatten(opt)
  #|}
  #|export let Option::is_none = [T](opt: Option[T]) -> Bool {
  #|  is_none(opt)
  #|}
  #|export let Option::is_some = [T](opt: Option[T]) -> Bool {
  #|  is_some(opt)
  #|}
  #|export let Option::map_opt = [A, B](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  #|  map_opt(opt, f)
  #|}
  #|export let Option::or_else = [T](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  #|  or_else(a, fallback)
  #|}
  #|export let Option::zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  #|  zip_sum(a, b)
  #|}
  #|export let Option::unwrap_or = [T](opt: Option[T], default: T) -> T {
  #|  unwrap_or(opt, default)
  #|}
  #|export let Option::unwrap_or_else = [T](opt: Option[T], fallback: () -> T) -> T {
  #|  unwrap_or_else(opt, fallback)
  #|}

///|
let builtin_result_source : String =
  #|
  #|export enum Result[T, E] {
  #|  Ok(T);
  #|  Err(E)
  #|}
  #|export let ok = [T, E](res: Result[T, E]) -> Option[T] {
  #|  match res {
  #|    Ok(value) => Some(value),
  #|    _ => None
  #|  }
  #|}
  #|export let err = [T, E](res: Result[T, E]) -> Option[E] {
  #|  match res {
  #|    Err(value) => Some(value),
  #|    _ => None
  #|  }
  #|}
  #|export let bind = [T, E, U](res: Result[T, E], f: (x: T) -> Result[U, E]) -> Result[U, E] {
  #|  match res {
  #|    Ok(value) => f(value),
  #|    Err(e) => Err(e)
  #|  }
  #|}
  #|export let is_ok = [T, E](res: Result[T, E]) -> Bool {
  #|  match res {
  #|    Ok(_) => true,
  #|    _ => false
  #|  }
  #|}
  #|export let is_err = [T, E](res: Result[T, E]) -> Bool {
  #|  not(is_ok(res))
  #|}
  #|export let map_ok = [T, E, U](res: Result[T, E], f: (x: T) -> U) -> Result[U, E] {
  #|  match res {
  #|    Ok(value) => Ok(f(value)),
  #|    Err(e) => Err(e)
  #|  }
  #|}
  #|export let map_or = [T, E, U](res: Result[T, E], default: U, f: (x: T) -> U) -> U {
  #|  match res {
  #|    Ok(value) => f(value),
  #|    _ => default
  #|  }
  #|}
  #|export let flatten = [T, E](res: Result[Result[T, E], E]) -> Result[T, E] {
  #|  match res {
  #|    Ok(inner) => inner,
  #|    Err(e) => Err(e)
  #|  }
  #|}
  #|export let map_err = [T, E, F](res: Result[T, E], f: (e: E) -> F) -> Result[T, F] {
  #|  match res {
  #|    Ok(value) => Ok(value),
  #|    Err(e) => Err(f(e))
  #|  }
  #|}
  #|export let and_then = [T, E, U](res: Result[T, E], f: (x: T) -> Result[U, E]) -> Result[U, E] {
  #|  bind(res, f)
  #|}
  #|export let equals_by = [T, E](a: Result[T, E], b: Result[T, E], ok_eq: (x: T, y: T) -> Bool, err_eq: (x: E, y: E) -> Bool) -> Bool {
  #|  match (a, b) {
  #|    (Ok(x), Ok(y)) => ok_eq(x, y),
  #|    (Err(x), Err(y)) => err_eq(x, y),
  #|    _ => false
  #|  }
  #|}
  #|export let to_option = [T, E](res: Result[T, E]) -> Option[T] {
  #|  ok(res)
  #|}
  #|export let unwrap_or = [T, E](res: Result[T, E], default: T) -> T {
  #|  match res {
  #|    Ok(value) => value,
  #|    _ => default
  #|  }
  #|}
  #|export let or = [T, E](res: Result[T, E], default: T) -> T {
  #|  unwrap_or(res, default)
  #|}
  #|export let from_option = [T, E](opt: Option[T], err_value: E) -> Result[T, E] {
  #|  match opt {
  #|    Some(value) => Ok(value),
  #|    _ => Err(err_value)
  #|  }
  #|}
  #|export let unwrap_or_else = [T, E](res: Result[T, E], fallback: () -> T) -> T {
  #|  match res {
  #|    Ok(value) => value,
  #|    _ => fallback()
  #|  }
  #|}
  #|export let or_else = [T, E](res: Result[T, E], fallback: () -> T) -> T {
  #|  unwrap_or_else(res, fallback)
  #|}
  #|export let Result::ok = [
  #|  T,
  #|  E
  #|](res: Result[T, E]) -> Option[T] {
  #|  ok(res)
  #|}
  #|export let Result::or = [
  #|  T,
  #|  E
  #|](res: Result[T, E], default: T) -> T {
  #|  or(res, default)
  #|}
  #|export let Result::err = [
  #|  T,
  #|  E
  #|](res: Result[T, E]) -> Option[E] {
  #|  err(res)
  #|}
  #|export let Result::bind = [
  #|  T,
  #|  E,
  #|  U
  #|](res: Result[T, E], f: (x: T) -> Result[U, E]) -> Result[U, E] {
  #|  bind(res, f)
  #|}
  #|export let Result::is_ok = [
  #|  T,
  #|  E
  #|](res: Result[T, E]) -> Bool {
  #|  is_ok(res)
  #|}
  #|export let Result::is_err = [
  #|  T,
  #|  E
  #|](res: Result[T, E]) -> Bool {
  #|  is_err(res)
  #|}
  #|export let Result::map_ok = [
  #|  T,
  #|  E,
  #|  U
  #|](res: Result[T, E], f: (x: T) -> U) -> Result[U, E] {
  #|  map_ok(res, f)
  #|}
  #|export let Result::map_or = [
  #|  T,
  #|  E,
  #|  U
  #|](res: Result[T, E], default: U, f: (x: T) -> U) -> U {
  #|  map_or(res, default, f)
  #|}
  #|export let Result::flatten = [
  #|  T,
  #|  E
  #|](res: Result[Result[T, E], E]) -> Result[T, E] {
  #|  flatten(res)
  #|}
  #|export let Result::map_err = [
  #|  T,
  #|  E,
  #|  F
  #|](res: Result[T, E], f: (e: E) -> F) -> Result[T, F] {
  #|  map_err(res, f)
  #|}
  #|export let Result::or_else = [
  #|  T,
  #|  E
  #|](res: Result[T, E], fallback: () -> T) -> T {
  #|  or_else(res, fallback)
  #|}
  #|export let Result::and_then = [
  #|  T,
  #|  E,
  #|  U
  #|](res: Result[T, E], f: (x: T) -> Result[U, E]) -> Result[U, E] {
  #|  and_then(res, f)
  #|}
  #|export let Result::equals_by = [
  #|  T,
  #|  E
  #|](a: Result[T, E], b: Result[T, E], ok_eq: (x: T, y: T) -> Bool, err_eq: (x: E, y: E) -> Bool) -> Bool {
  #|  equals_by(a, b, ok_eq, err_eq)
  #|}
  #|export let Result::to_option = [
  #|  T,
  #|  E
  #|](res: Result[T, E]) -> Option[T] {
  #|  to_option(res)
  #|}
  #|export let Result::unwrap_or = [
  #|  T,
  #|  E
  #|](res: Result[T, E], default: T) -> T {
  #|  unwrap_or(res, default)
  #|}
  #|export let Result::unwrap_or_else = [
  #|  T,
  #|  E
  #|](res: Result[T, E], fallback: () -> T) -> T {
  #|  unwrap_or_else(res, fallback)
  #|}

///|
let builtin_cmp_source : String =
  #|
  #|export let minmax = (a: Int, b: Int) -> (Int, Int) {
  #|  if a <= b {
  #|    (a, b)
  #|  } else {
  #|    (b, a)
  #|  }
  #|}
  #|export let maximum = (a: Int, b: Int) -> Int {
  #|  if a > b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let minimum = (a: Int, b: Int) -> Int {
  #|  if a < b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let minmax_by = [T](a: T, b: T, compare: (x: T, y: T) -> Int) -> (T, T) {
  #|  if compare(a, b) <= 0 {
  #|    (a, b)
  #|  } else {
  #|    (b, a)
  #|  }
  #|}
  #|export let maximum_by = [T](a: T, b: T, compare: (x: T, y: T) -> Int) -> T {
  #|  if compare(a, b) >= 0 {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let minimum_by = [T](a: T, b: T, compare: (x: T, y: T) -> Int) -> T {
  #|  if compare(a, b) <= 0 {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let int_compare = (a: Int, b: Int) -> Int {
  #|  if a < b {
  #|    -1
  #|  }
  #|  else if a > b {
  #|    1
  #|  }
  #|  else {
  #|    0
  #|  }
  #|}
  #|export let float_compare = (a: Float, b: Float) -> Int {
  #|  if a < b {
  #|    -1
  #|  }
  #|  else if a > b {
  #|    1
  #|  }
  #|  else {
  #|    0
  #|  }
  #|}
  #|export let minmax_by_key = [T, K](a: T, b: T, key: (x: T) -> K, compare_key: (x: K, y: K) -> Int) -> (T, T) {
  #|  minmax_by(a, b, (x: T, y: T) -> Int {
  #|    compare_key(key(x), key(y))
  #|  })
  #|}
  #|export let double_compare = (a: Double, b: Double) -> Int {
  #|  if a < b {
  #|    -1
  #|  }
  #|  else if a > b {
  #|    1
  #|  }
  #|  else {
  #|    0
  #|  }
  #|}
  #|export let maximum_by_key = [T, K](a: T, b: T, key: (x: T) -> K, compare_key: (x: K, y: K) -> Int) -> T {
  #|  maximum_by(a, b, (x: T, y: T) -> Int {
  #|    compare_key(key(x), key(y))
  #|  })
  #|}
  #|export let minimum_by_key = [T, K](a: T, b: T, key: (x: T) -> K, compare_key: (x: K, y: K) -> Int) -> T {
  #|  minimum_by(a, b, (x: T, y: T) -> Int {
  #|    compare_key(key(x), key(y))
  #|  })
  #|}
  #|export let string_compare = (a: String, b: String) -> Int {
  #|  if a < b {
  #|    -1
  #|  }
  #|  else if a > b {
  #|    1
  #|  }
  #|  else {
  #|    0
  #|  }
  #|}

///|
let builtin_bool_source : String =
  #|
  #|export let bool_nor = (a: Bool, b: Bool) -> Bool {
  #|  not(a || b)
  #|}
  #|export let nor = (a: Bool, b: Bool) -> Bool {
  #|  bool_nor(a, b)
  #|}
  #|export let bool_xor = (a: Bool, b: Bool) -> Bool {
  #|  if a {
  #|    not(b)
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let xor = (a: Bool, b: Bool) -> Bool {
  #|  bool_xor(a, b)
  #|}
  #|export let bool_all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  a && b && c
  #|}
  #|export let all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  bool_all3(a, b, c)
  #|}
  #|export let bool_any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  a || b || c
  #|}
  #|export let any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  bool_any3(a, b, c)
  #|}
  #|export let bool_nand = (a: Bool, b: Bool) -> Bool {
  #|  not(a && b)
  #|}
  #|export let nand = (a: Bool, b: Bool) -> Bool {
  #|  bool_nand(a, b)
  #|}
  #|export let bool_to_int = (b: Bool) -> Int {
  #|  if b {
  #|    1
  #|  } else {
  #|    0
  #|  }
  #|}
  #|export let to_int = (b: Bool) -> Int {
  #|  bool_to_int(b)
  #|}
  #|export let int_to_bool = (n: Int) -> Bool {
  #|  n != 0
  #|}
  #|export let from_int = (n: Int) -> Bool {
  #|  int_to_bool(n)
  #|}
  #|export let bool_implies = (a: Bool, b: Bool) -> Bool {
  #|  if a {
  #|    b
  #|  } else {
  #|    true
  #|  }
  #|}
  #|export let implies = (a: Bool, b: Bool) -> Bool {
  #|  bool_implies(a, b)
  #|}
  #|export let Bool::nor = (a: Bool, b: Bool) -> Bool {
  #|  bool_nor(a, b)
  #|}
  #|export let Bool::xor = (a: Bool, b: Bool) -> Bool {
  #|  bool_xor(a, b)
  #|}
  #|export let Bool::all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  bool_all3(a, b, c)
  #|}
  #|export let Bool::any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  #|  bool_any3(a, b, c)
  #|}
  #|export let Bool::nand = (a: Bool, b: Bool) -> Bool {
  #|  bool_nand(a, b)
  #|}
  #|export let Bool::to_int = (b: Bool) -> Int {
  #|  bool_to_int(b)
  #|}
  #|export let Bool::implies = (a: Bool, b: Bool) -> Bool {
  #|  bool_implies(a, b)
  #|}

///|
let builtin_int_source : String =
  #|
  #|declare export let max_value: Int
  #|declare export let min_value: Int
  #|let int_max = (a: Int, b: Int) -> Int {
  #|  if a > b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let max = (a: Int, b: Int) -> Int {
  #|  int_max(a, b)
  #|}
  #|let int_min = (a: Int, b: Int) -> Int {
  #|  if a < b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|export let min = (a: Int, b: Int) -> Int {
  #|  int_min(a, b)
  #|}
  #|let rec int_pow = (base: Int, exp: Int) -> Int {
  #|  if exp <= 0 {
  #|    1
  #|  }
  #|  else if exp == 1 {
  #|    base
  #|  }
  #|  else if exp % 2 == 0 {
  #|    let half = int_pow(base, exp / 2)
  #|    half * half
  #|  } else {
  #|    base * int_pow(base, exp - 1)
  #|  }
  #|}
  #|export let pow = (base: Int, exp: Int) -> Int {
  #|  int_pow(base, exp)
  #|}
  #|let int_clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  #|  if x < min_val {
  #|    min_val
  #|  }
  #|  else if x > max_val {
  #|    max_val
  #|  }
  #|  else {
  #|    x
  #|  }
  #|}
  #|export let clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  #|  int_clamp(x, min_val, max_val)
  #|}
  #|let int_is_odd = (x: Int) -> Bool {
  #|  x % 2 != 0
  #|}
  #|export let is_odd = (x: Int) -> Bool {
  #|  int_is_odd(x)
  #|}
  #|let int_signum = (x: Int) -> Int {
  #|  if x < 0 {
  #|    -1
  #|  }
  #|  else if x > 0 {
  #|    1
  #|  }
  #|  else {
  #|    0
  #|  }
  #|}
  #|export let signum = (x: Int) -> Int {
  #|  int_signum(x)
  #|}
  #|let int_is_even = (x: Int) -> Bool {
  #|  x % 2 == 0
  #|}
  #|export let is_even = (x: Int) -> Bool {
  #|  int_is_even(x)
  #|}
  #|let int_is_zero = (x: Int) -> Bool {
  #|  x == 0
  #|}
  #|export let is_zero = (x: Int) -> Bool {
  #|  int_is_zero(x)
  #|}
  #|let rec int_factorial = (n: Int) -> Int {
  #|  if n <= 1 {
  #|    1
  #|  }
  #|  else {
  #|    n * int_factorial(n - 1)
  #|  }
  #|}
  #|export let factorial = (n: Int) -> Int {
  #|  int_factorial(n)
  #|}
  #|let int_fibonacci = (n: Int) -> Int {
  #|  let rec fib = (a: Int, b: Int, count: Int) -> Int {
  #|    if count <= 0 {
  #|      a
  #|    }
  #|    else {
  #|      fib(b, a + b, count - 1)
  #|    }
  #|  }
  #|  fib(0, 1, n)
  #|}
  #|export let fibonacci = (n: Int) -> Int {
  #|  int_fibonacci(n)
  #|}
  #|let int_max_value: Int = 2305843009213693951
  #|max_value = int_max_value
  #|let int_min_value: Int = 0 - 2305843009213693951 - 1
  #|let int_abs = (x: Int) -> Int {
  #|  if x == int_min_value {
  #|    int_max_value
  #|  }
  #|  else if x < 0 {
  #|    0 - x
  #|  }
  #|  else {
  #|    x
  #|  }
  #|}
  #|export let abs = (x: Int) -> Int {
  #|  int_abs(x)
  #|}
  #|let rec int_gcd = (a: Int, b: Int) -> Int {
  #|  let abs_a = int_abs(a)
  #|  let abs_b = int_abs(b)
  #|  if abs_b == 0 {
  #|    abs_a
  #|  }
  #|  else {
  #|    int_gcd(abs_b, abs_a % abs_b)
  #|  }
  #|}
  #|export let gcd = (a: Int, b: Int) -> Int {
  #|  int_gcd(a, b)
  #|}
  #|let int_lcm = (a: Int, b: Int) -> Int {
  #|  if a == 0 || b == 0 {
  #|    0
  #|  }
  #|  else {
  #|    let g = int_gcd(a, b)
  #|    let scaled = a / g
  #|    int_abs(scaled * b)
  #|  }
  #|}
  #|export let lcm = (a: Int, b: Int) -> Int {
  #|  int_lcm(a, b)
  #|}
  #|min_value = int_min_value
  #|let int_is_negative = (x: Int) -> Bool {
  #|  x < 0
  #|}
  #|export let is_negative = (x: Int) -> Bool {
  #|  int_is_negative(x)
  #|}
  #|let int_is_positive = (x: Int) -> Bool {
  #|  x > 0
  #|}
  #|export let is_positive = (x: Int) -> Bool {
  #|  int_is_positive(x)
  #|}
  #|export let Int::abs = (x: Int) -> Int {
  #|  int_abs(x)
  #|}
  #|export let Int::gcd = (a: Int, b: Int) -> Int {
  #|  int_gcd(a, b)
  #|}
  #|export let Int::lcm = (a: Int, b: Int) -> Int {
  #|  int_lcm(a, b)
  #|}
  #|export let Int::max = (a: Int, b: Int) -> Int {
  #|  int_max(a, b)
  #|}
  #|export let Int::min = (a: Int, b: Int) -> Int {
  #|  int_min(a, b)
  #|}
  #|export let Int::pow = (base: Int, exp: Int) -> Int {
  #|  int_pow(base, exp)
  #|}
  #|export let Int::clamp = (x: Int, min_val: Int, max_val: Int) -> Int {
  #|  int_clamp(x, min_val, max_val)
  #|}
  #|export let Int::is_odd = (x: Int) -> Bool {
  #|  int_is_odd(x)
  #|}
  #|export let Int::signum = (x: Int) -> Int {
  #|  int_signum(x)
  #|}
  #|export let Int::is_even = (x: Int) -> Bool {
  #|  int_is_even(x)
  #|}
  #|export let Int::is_zero = (x: Int) -> Bool {
  #|  int_is_zero(x)
  #|}
  #|export let Int::factorial = (n: Int) -> Int {
  #|  int_factorial(n)
  #|}
  #|export let Int::fibonacci = (n: Int) -> Int {
  #|  int_fibonacci(n)
  #|}
  #|export let Int::to_double = (x: Int) -> Double {
  #|  int_to_double(x)
  #|}
  #|export let Int::is_negative = (x: Int) -> Bool {
  #|  int_is_negative(x)
  #|}
  #|export let Int::is_positive = (x: Int) -> Bool {
  #|  int_is_positive(x)
  #|}

///|
let builtin_float_source : String =
  #|
  #|declare export let eq: (Float, Float) -> Bool
  #|declare export let abs: (Float) -> Float
  #|declare export let max: (Float, Float) -> Float
  #|declare export let min: (Float, Float) -> Float
  #|declare export let lerp: (Float, Float, Float) -> Float
  #|declare export let clamp: (Float, Float, Float) -> Float
  #|declare export let is_nan: (Float) -> Bool
  #|declare export let signum: (Float) -> Float
  #|declare export let square: (Float) -> Float
  #|declare export let is_zero: (Float) -> Bool
  #|declare export let is_negative: (Float) -> Bool
  #|declare export let is_positive: (Float) -> Bool
  #|let float_eq = (a: Float, b: Float) -> Bool {
  #|  a == b
  #|}
  #|eq = float_eq
  #|let float_abs = (x: Float) -> Float {
  #|  if x < 0.0f {
  #|    0.0f - x
  #|  } else {
  #|    x
  #|  }
  #|}
  #|abs = float_abs
  #|let float_max = (a: Float, b: Float) -> Float {
  #|  if a > b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|max = float_max
  #|let float_min = (a: Float, b: Float) -> Float {
  #|  if a < b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|min = float_min
  #|let float_lerp = (a: Float, b: Float, t: Float) -> Float {
  #|  a + (b - a) * t
  #|}
  #|lerp = float_lerp
  #|let float_clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  #|  if x < min_val {
  #|    min_val
  #|  }
  #|  else if x > max_val {
  #|    max_val
  #|  }
  #|  else {
  #|    x
  #|  }
  #|}
  #|clamp = float_clamp
  #|let float_is_nan = (x: Float) -> Bool {
  #|  not(x == x)
  #|}
  #|is_nan = float_is_nan
  #|let float_signum = (x: Float) -> Float {
  #|  if x < 0.0f {
  #|    0.0f - 1.0f
  #|  }
  #|  else if x > 0.0f {
  #|    1.0f
  #|  }
  #|  else {
  #|    0.0f
  #|  }
  #|}
  #|signum = float_signum
  #|let float_square = (x: Float) -> Float {
  #|  x * x
  #|}
  #|square = float_square
  #|let float_is_zero = (x: Float) -> Bool {
  #|  x == 0.0f
  #|}
  #|is_zero = float_is_zero
  #|let float_is_negative = (x: Float) -> Bool {
  #|  x < 0.0f
  #|}
  #|is_negative = float_is_negative
  #|let float_is_positive = (x: Float) -> Bool {
  #|  x > 0.0f
  #|}
  #|is_positive = float_is_positive
  #|export let Float::eq = (a: Float, b: Float) -> Bool {
  #|  float_eq(a, b)
  #|}
  #|export let Float::abs = (x: Float) -> Float {
  #|  float_abs(x)
  #|}
  #|export let Float::max = (a: Float, b: Float) -> Float {
  #|  float_max(a, b)
  #|}
  #|export let Float::min = (a: Float, b: Float) -> Float {
  #|  float_min(a, b)
  #|}
  #|export let Float::lerp = (a: Float, b: Float, t: Float) -> Float {
  #|  float_lerp(a, b, t)
  #|}
  #|export let Float::clamp = (x: Float, min_val: Float, max_val: Float) -> Float {
  #|  float_clamp(x, min_val, max_val)
  #|}
  #|export let Float::is_nan = (x: Float) -> Bool {
  #|  float_is_nan(x)
  #|}
  #|export let Float::signum = (x: Float) -> Float {
  #|  float_signum(x)
  #|}
  #|export let Float::square = (x: Float) -> Float {
  #|  float_square(x)
  #|}
  #|export let Float::is_zero = (x: Float) -> Bool {
  #|  float_is_zero(x)
  #|}
  #|export let Float::is_negative = (x: Float) -> Bool {
  #|  float_is_negative(x)
  #|}
  #|export let Float::is_positive = (x: Float) -> Bool {
  #|  float_is_positive(x)
  #|}

///|
let builtin_double_source : String =
  #|
  #|declare export let abs: (Double) -> Double
  #|declare export let max: (Double, Double) -> Double
  #|declare export let min: (Double, Double) -> Double
  #|declare export let cube: (Double) -> Double
  #|declare export let lerp: (Double, Double, Double) -> Double
  #|declare export let clamp: (Double, Double, Double) -> Double
  #|declare export let is_nan: (Double) -> Bool
  #|declare export let signum: (Double) -> Double
  #|declare export let square: (Double) -> Double
  #|declare export let approx_eq: (Double, Double, Double) -> Bool
  #|declare export let ceil: (Double) -> Double
  #|declare export let floor: (Double) -> Double
  #|declare export let round: (Double) -> Double
  #|declare export let trunc: (Double) -> Double
  #|declare export let fract: (Double) -> Double
  #|let double_abs = (x: Double) -> Double {
  #|  if x < 0.0 {
  #|    0.0 - x
  #|  } else {
  #|    x
  #|  }
  #|}
  #|abs = double_abs
  #|let double_max = (a: Double, b: Double) -> Double {
  #|  if a > b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|max = double_max
  #|let double_min = (a: Double, b: Double) -> Double {
  #|  if a < b {
  #|    a
  #|  } else {
  #|    b
  #|  }
  #|}
  #|min = double_min
  #|let double_cube = (x: Double) -> Double {
  #|  x * x * x
  #|}
  #|cube = double_cube
  #|let double_lerp = (a: Double, b: Double, t: Double) -> Double {
  #|  a + (b - a) * t
  #|}
  #|lerp = double_lerp
  #|let double_clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  #|  if x < min_val {
  #|    min_val
  #|  }
  #|  else if x > max_val {
  #|    max_val
  #|  }
  #|  else {
  #|    x
  #|  }
  #|}
  #|clamp = double_clamp
  #|let double_is_nan = (x: Double) -> Bool {
  #|  not(x == x)
  #|}
  #|is_nan = double_is_nan
  #|let double_signum = (x: Double) -> Double {
  #|  if x < 0.0 {
  #|    -1.0
  #|  }
  #|  else if x > 0.0 {
  #|    1.0
  #|  }
  #|  else {
  #|    0.0
  #|  }
  #|}
  #|signum = double_signum
  #|let double_square = (x: Double) -> Double {
  #|  x * x
  #|}
  #|square = double_square
  #|let double_int_max: Int = 2305843009213693951
  #|let double_int_min: Int = 0 - 2305843009213693951 - 1
  #|let double_approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  #|  double_abs(a - b) <= eps
  #|}
  #|approx_eq = double_approx_eq
  #|let double_int_max_value: Double = int_to_double(double_int_max)
  #|let double_int_min_value: Double = int_to_double(double_int_min)
  #|let double_to_int_saturating = (x: Double) -> Int {
  #|  if x >= double_int_max_value {
  #|    double_int_max
  #|  }
  #|  else if x <= double_int_min_value {
  #|    double_int_min
  #|  }
  #|  else {
  #|    double_to_int(x)
  #|  }
  #|}
  #|let double_ceil = (x: Double) -> Double {
  #|  if x >= double_int_max_value {
  #|    double_int_max_value
  #|  } else {
  #|    let i = double_to_int_saturating(x)
  #|    let d = int_to_double(i)
  #|    if d < x {
  #|      int_to_double(i + 1)
  #|    } else {
  #|      d
  #|    }
  #|  }
  #|}
  #|ceil = double_ceil
  #|let double_floor = (x: Double) -> Double {
  #|  if x <= double_int_min_value {
  #|    double_int_min_value
  #|  } else {
  #|    let i = double_to_int_saturating(x)
  #|    let d = int_to_double(i)
  #|    if d > x {
  #|      int_to_double(i - 1)
  #|    } else {
  #|      d
  #|    }
  #|  }
  #|}
  #|floor = double_floor
  #|let double_round = (x: Double) -> Double {
  #|  if x >= 0.0 {
  #|    double_floor(x + 0.5)
  #|  } else {
  #|    double_ceil(x - 0.5)
  #|  }
  #|}
  #|round = double_round
  #|let double_trunc = (x: Double) -> Double {
  #|  int_to_double(double_to_int_saturating(x))
  #|}
  #|trunc = double_trunc
  #|let double_fract = (x: Double) -> Double {
  #|  x - double_trunc(x)
  #|}
  #|fract = double_fract
  #|export let Double::abs = (x: Double) -> Double {
  #|  double_abs(x)
  #|}
  #|export let Double::max = (a: Double, b: Double) -> Double {
  #|  double_max(a, b)
  #|}
  #|export let Double::min = (a: Double, b: Double) -> Double {
  #|  double_min(a, b)
  #|}
  #|export let Double::ceil = (x: Double) -> Double {
  #|  double_ceil(x)
  #|}
  #|export let Double::cube = (x: Double) -> Double {
  #|  double_cube(x)
  #|}
  #|export let Double::lerp = (a: Double, b: Double, t: Double) -> Double {
  #|  double_lerp(a, b, t)
  #|}
  #|export let Double::clamp = (x: Double, min_val: Double, max_val: Double) -> Double {
  #|  double_clamp(x, min_val, max_val)
  #|}
  #|export let Double::floor = (x: Double) -> Double {
  #|  double_floor(x)
  #|}
  #|export let Double::fract = (x: Double) -> Double {
  #|  double_fract(x)
  #|}
  #|export let Double::round = (x: Double) -> Double {
  #|  double_round(x)
  #|}
  #|export let Double::trunc = (x: Double) -> Double {
  #|  double_trunc(x)
  #|}
  #|export let Double::is_nan = (x: Double) -> Bool {
  #|  double_is_nan(x)
  #|}
  #|export let Double::signum = (x: Double) -> Double {
  #|  double_signum(x)
  #|}
  #|export let Double::square = (x: Double) -> Double {
  #|  double_square(x)
  #|}
  #|export let Double::approx_eq = (a: Double, b: Double, eps: Double) -> Bool {
  #|  double_approx_eq(a, b, eps)
  #|}

///|
let builtin_char_source : String =
  #|
  #|export let to_int = (ch: Char) -> Int {
  #|  char_to_int(ch)
  #|}
  #|export let from_int = (code: Int) -> Option[Char] {
  #|  if code < 0 || code > 1114111 {
  #|    None
  #|  } else {
  #|    Some(char_from_int(code))
  #|  }
  #|}
  #|export let is_ascii = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  code >= 0 && code <= 127
  #|}
  #|export let to_string = (ch: Char) -> String {
  #|  __to_string(ch)
  #|}
  #|export let from_string = (s: String) -> Option[Char] {
  #|  if string_length(s) == 1 {
  #|    from_int(string_char_code_at(s, 0))
  #|  } else {
  #|    None
  #|  }
  #|}
  #|export let is_ascii_digit = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  code >= 48 && code <= 57
  #|}
  #|export let is_ascii_hexdigit = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  is_ascii_digit(ch)
  #|  || (code >= 65 && code <= 70)
  #|  || (code >= 97 && code <= 102)
  #|}
  #|export let is_ascii_lowercase = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  code >= 97 && code <= 122
  #|}
  #|export let is_ascii_uppercase = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  code >= 65 && code <= 90
  #|}
  #|export let to_ascii_lowercase = (ch: Char) -> Char {
  #|  if is_ascii_uppercase(ch) {
  #|    char_from_int(to_int(ch) + 32)
  #|  } else {
  #|    ch
  #|  }
  #|}
  #|export let to_ascii_uppercase = (ch: Char) -> Char {
  #|  if is_ascii_lowercase(ch) {
  #|    char_from_int(to_int(ch) - 32)
  #|  } else {
  #|    ch
  #|  }
  #|}
  #|export let is_ascii_alphabetic = (ch: Char) -> Bool {
  #|  is_ascii_lowercase(ch) || is_ascii_uppercase(ch)
  #|}
  #|export let is_ascii_alnum = (ch: Char) -> Bool {
  #|  is_ascii_alphabetic(ch) || is_ascii_digit(ch)
  #|}
  #|export let is_ascii_whitespace = (ch: Char) -> Bool {
  #|  let code = to_int(ch)
  #|  code == 32 || code == 9 || code == 10 || code == 11 || code == 12 || code == 13
  #|}

///|
let builtin_string_source : String =
  #|
  #|let string_drop = (s: String, n: Int) -> String {
  #|  let len = string_length(s)
  #|  if n <= 0 {
  #|    s
  #|  }
  #|  else if n >= len {
  #|    ""
  #|  }
  #|  else {
  #|    string_substring(s, n, len)
  #|  }
  #|}
  #|let string_head = (s: String) -> String {
  #|  if string_length(s) == 0 {
  #|    ""
  #|  }
  #|  else {
  #|    string_substring(s, 0, 1)
  #|  }
  #|}
  #|let string_init = (s: String) -> String {
  #|  let len = string_length(s)
  #|  if len <= 1 {
  #|    ""
  #|  }
  #|  else {
  #|    string_substring(s, 0, len - 1)
  #|  }
  #|}
  #|let string_last = (s: String) -> String {
  #|  let len = string_length(s)
  #|  if len == 0 {
  #|    ""
  #|  }
  #|  else {
  #|    string_substring(s, len - 1, len)
  #|  }
  #|}
  #|let string_tail = (s: String) -> String {
  #|  let len = string_length(s)
  #|  if len <= 1 {
  #|    ""
  #|  }
  #|  else {
  #|    string_substring(s, 1, len)
  #|  }
  #|}
  #|let string_take = (s: String, n: Int) -> String {
  #|  let len = string_length(s)
  #|  if n <= 0 {
  #|    ""
  #|  }
  #|  else if n >= len {
  #|    s
  #|  }
  #|  else {
  #|    string_substring(s, 0, n)
  #|  }
  #|}
  #|let string_count = (s: String, sub: String) -> Int {
  #|  let s_len = string_length(s)
  #|  let sub_len = string_length(sub)
  #|  if sub_len == 0 || sub_len > s_len {
  #|    0
  #|  }
  #|  else {
  #|    let rec go = (i: Int, acc: Int) -> Int {
  #|      if i > s_len - sub_len {
  #|        acc
  #|      }
  #|      else if string_equals(string_substring(s, i, i + sub_len), sub) {
  #|        go(i + sub_len, acc + 1)
  #|      } else {
  #|        go(i + 1, acc)
  #|      }
  #|    }
  #|    go(0, 0)
  #|  }
  #|}
  #|let string_repeat = (s: String, n: Int) -> String {
  #|  let rec go = (acc: String, chunk: String, count: Int) -> String {
  #|    if count <= 0 {
  #|      acc
  #|    }
  #|    else if count % 2 == 1 {
  #|      go(string_concat(acc, chunk), string_concat(chunk, chunk), count / 2)
  #|    } else {
  #|      go(acc, string_concat(chunk, chunk), count / 2)
  #|    }
  #|  }
  #|  go("", s, n)
  #|}
  #|export let from_char_code = (code: Int) -> String {
  #|  string_from_char_code(code)
  #|}
  #|let string_compare = (a: String, b: String) -> Int {
  #|  if string_equals(a, b) {
  #|    0
  #|  }
  #|  else if a < b {
  #|    -1
  #|  }
  #|  else {
  #|    1
  #|  }
  #|}
  #|let string_is_empty = (s: String) -> Bool {
  #|  string_length(s) == 0
  #|}
  #|let string_build_pad = (pad_char: String, pad_len: Int) -> String {
  #|  if pad_len <= 0 {
  #|    ""
  #|  }
  #|  else {
  #|    let unit_len = string_length(pad_char)
  #|    if unit_len == 0 {
  #|      ""
  #|    }
  #|    else {
  #|      let repeats = (pad_len + unit_len - 1) / unit_len
  #|      string_take(string_repeat(pad_char, repeats), pad_len)
  #|    }
  #|  }
  #|}
  #|let string_pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  #|  let len = string_length(s)
  #|  let pad_len = target_len - len
  #|  if pad_len <= 0 {
  #|    s
  #|  }
  #|  else {
  #|    let pad = string_build_pad(pad_char, pad_len)
  #|    if string_length(pad) == 0 {
  #|      s
  #|    } else {
  #|      string_concat(pad, s)
  #|    }
  #|  }
  #|}
  #|let string_ends_with = (s: String, suffix: String) -> Bool {
  #|  let s_len = string_length(s)
  #|  let suf_len = string_length(suffix)
  #|  if suf_len > s_len {
  #|    false
  #|  }
  #|  else {
  #|    string_equals(string_substring(s, s_len - suf_len, s_len), suffix)
  #|  }
  #|}
  #|let string_pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  #|  let len = string_length(s)
  #|  let pad_len = target_len - len
  #|  if pad_len <= 0 {
  #|    s
  #|  }
  #|  else {
  #|    let pad = string_build_pad(pad_char, pad_len)
  #|    if string_length(pad) == 0 {
  #|      s
  #|    } else {
  #|      string_concat(s, pad)
  #|    }
  #|  }
  #|}
  #|let string_starts_with = (s: String, prefix: String) -> Bool {
  #|  let s_len = string_length(s)
  #|  let p_len = string_length(prefix)
  #|  if p_len > s_len {
  #|    false
  #|  }
  #|  else {
  #|    string_equals(string_substring(s, 0, p_len), prefix)
  #|  }
  #|}
  #|let is_ascii_whitespace = (code: Int) -> Bool {
  #|  code == 32 || code == 9 || code == 10 || code == 13
  #|}
  #|let string_trim_end = (s: String) -> String {
  #|  let len = string_length(s)
  #|  let rec find_end = (i: Int) -> Int {
  #|    if i <= 0 {
  #|      0
  #|    }
  #|    else {
  #|      let code = string_char_code_at(s, i - 1)
  #|      if is_ascii_whitespace(code) {
  #|        find_end(i - 1)
  #|      }
  #|      else {
  #|        i
  #|      }
  #|    }
  #|  }
  #|  let end = find_end(len)
  #|  if end == len {
  #|    s
  #|  }
  #|  else {
  #|    string_substring(s, 0, end)
  #|  }
  #|}
  #|let string_trim_start = (s: String) -> String {
  #|  let len = string_length(s)
  #|  let rec find_start = (i: Int) -> Int {
  #|    if i >= len {
  #|      len
  #|    }
  #|    else {
  #|      let code = string_char_code_at(s, i)
  #|      if is_ascii_whitespace(code) {
  #|        find_start(i + 1)
  #|      }
  #|      else {
  #|        i
  #|      }
  #|    }
  #|  }
  #|  let start = find_start(0)
  #|  if start == 0 {
  #|    s
  #|  }
  #|  else {
  #|    string_substring(s, start, len)
  #|  }
  #|}
  #|let string_trim = (s: String) -> String {
  #|  string_trim_end(string_trim_start(s))
  #|}
  #|let string_is_blank = (s: String) -> Bool {
  #|  string_is_empty(string_trim(s))
  #|}
  #|let string_equals_value = (a: String, b: String) -> Bool {
  #|  string_equals(a, b)
  #|}
  #|let string_is_not_empty = (s: String) -> Bool {
  #|  string_length(s) > 0
  #|}
  #|let string_index_of_from = (s: String, sub: String, start: Int) -> Int {
  #|  let s_len = string_length(s)
  #|  let sub_len = string_length(sub)
  #|  if start < 0 {
  #|    -1
  #|  }
  #|  else if sub_len == 0 {
  #|    if start <= s_len {
  #|      start
  #|    } else {
  #|      -1
  #|    }
  #|  }
  #|  else if sub_len > s_len || start > s_len - sub_len {
  #|    -1
  #|  }
  #|  else {
  #|    let rec find = (i: Int) -> Int {
  #|      if i > s_len - sub_len {
  #|        -1
  #|      }
  #|      else if string_equals(string_substring(s, i, i + sub_len), sub) {
  #|        i
  #|      }
  #|      else {
  #|        find(i + 1)
  #|      }
  #|    }
  #|    find(start)
  #|  }
  #|}
  #|let string_contains = (s: String, sub: String) -> Bool {
  #|  string_index_of_from(s, sub, 0) >= 0
  #|}
  #|let string_index_of = (s: String, sub: String) -> Int {
  #|  string_index_of_from(s, sub, 0)
  #|}
  #|let string_replace = (s: String, pattern: String, replacement: String) -> String {
  #|  let pat_len = string_length(pattern)
  #|  if pat_len == 0 {
  #|    s
  #|  }
  #|  else {
  #|    let idx = string_index_of(s, pattern)
  #|    if idx < 0 {
  #|      s
  #|    }
  #|    else {
  #|      let before = string_substring(s, 0, idx)
  #|      let after = string_substring(s, idx + pat_len, string_length(s))
  #|      string_concat(string_concat(before, replacement), after)
  #|    }
  #|  }
  #|}
  #|let string_replace_all = (s: String, pattern: String, replacement: String) -> String {
  #|  let pat_len = string_length(pattern)
  #|  let s_len = string_length(s)
  #|  if pat_len == 0 || pat_len > s_len {
  #|    s
  #|  }
  #|  else {
  #|    let rec go = (start: Int, sb: StringBuilder) -> String {
  #|      let idx = string_index_of_from(s, pattern, start)
  #|      if idx < 0 {
  #|        let rest = string_substring(s, start, s_len)
  #|        do {
  #|          string_builder_push(sb, rest)
  #|          string_builder_freeze(sb)
  #|        }
  #|      } else {
  #|        let before = string_substring(s, start, idx)
  #|        do {
  #|          string_builder_push(sb, before)
  #|          string_builder_push(sb, replacement)
  #|        }
  #|        go(idx + pat_len, sb)
  #|      }
  #|    }
  #|    do {
  #|      go(0, string_builder())
  #|    }
  #|  }
  #|}
  #|let string_last_index_of = (s: String, sub: String) -> Int {
  #|  let s_len = string_length(s)
  #|  let sub_len = string_length(sub)
  #|  if sub_len > s_len {
  #|    -1
  #|  }
  #|  else if sub_len == 0 {
  #|    s_len
  #|  }
  #|  else {
  #|    let rec find = (i: Int) -> Int {
  #|      if i < 0 {
  #|        -1
  #|      }
  #|      else if string_equals(string_substring(s, i, i + sub_len), sub) {
  #|        i
  #|      }
  #|      else {
  #|        find(i - 1)
  #|      }
  #|    }
  #|    find(s_len - sub_len)
  #|  }
  #|}
  #|let string_utf8_length_value = (s: String) -> Int {
  #|  string_utf8_length(s)
  #|}
  #|let string_utf16_length_value = (s: String) -> Int {
  #|  string_utf16_length(s)
  #|}
  #|let string_unicode_length_value = (s: String) -> Int {
  #|  string_unicode_length(s)
  #|}
  #|export let String::drop = (s: String, n: Int) -> String {
  #|  string_drop(s, n)
  #|}
  #|export let String::head = (s: String) -> String {
  #|  string_head(s)
  #|}
  #|export let String::init = (s: String) -> String {
  #|  string_init(s)
  #|}
  #|export let String::last = (s: String) -> String {
  #|  string_last(s)
  #|}
  #|export let String::tail = (s: String) -> String {
  #|  string_tail(s)
  #|}
  #|export let String::take = (s: String, n: Int) -> String {
  #|  string_take(s, n)
  #|}
  #|export let String::trim = (s: String) -> String {
  #|  string_trim(s)
  #|}
  #|export let String::count = (s: String, sub: String) -> Int {
  #|  string_count(s, sub)
  #|}
  #|export let String::equals = (a: String, b: String) -> Bool {
  #|  string_equals_value(a, b)
  #|}
  #|export let String::repeat = (s: String, n: Int) -> String {
  #|  string_repeat(s, n)
  #|}
  #|export let String::compare = (a: String, b: String) -> Int {
  #|  string_compare(a, b)
  #|}
  #|export let String::replace = (s: String, pattern: String, replacement: String) -> String {
  #|  string_replace(s, pattern, replacement)
  #|}
  #|export let String::contains = (s: String, sub: String) -> Bool {
  #|  string_contains(s, sub)
  #|}
  #|export let String::index_of = (s: String, sub: String) -> Int {
  #|  string_index_of(s, sub)
  #|}
  #|export let String::is_blank = (s: String) -> Bool {
  #|  string_is_blank(s)
  #|}
  #|export let String::is_empty = (s: String) -> Bool {
  #|  string_is_empty(s)
  #|}
  #|export let String::pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  #|  string_pad_left(s, target_len, pad_char)
  #|}
  #|export let String::trim_end = (s: String) -> String {
  #|  string_trim_end(s)
  #|}
  #|export let String::ends_with = (s: String, suffix: String) -> Bool {
  #|  string_ends_with(s, suffix)
  #|}
  #|export let String::pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  #|  string_pad_right(s, target_len, pad_char)
  #|}
  #|export let String::trim_start = (s: String) -> String {
  #|  string_trim_start(s)
  #|}
  #|export let String::replace_all = (s: String, pattern: String, replacement: String) -> String {
  #|  string_replace_all(s, pattern, replacement)
  #|}
  #|export let String::starts_with = (s: String, prefix: String) -> Bool {
  #|  string_starts_with(s, prefix)
  #|}
  #|export let String::utf8_length = (s: String) -> Int {
  #|  string_utf8_length_value(s)
  #|}
  #|export let String::is_not_empty = (s: String) -> Bool {
  #|  string_is_not_empty(s)
  #|}
  #|export let String::utf16_length = (s: String) -> Int {
  #|  string_utf16_length_value(s)
  #|}
  #|export let String::last_index_of = (s: String, sub: String) -> Int {
  #|  string_last_index_of(s, sub)
  #|}
  #|export let String::unicode_length = (s: String) -> Int {
  #|  string_unicode_length_value(s)
  #|}

///|
let builtin_array_source : String =
  #|
  #|export let all = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  let len = array_length(xs)
  #|  let rec r#loop = (i: Int) -> Bool {
  #|    if i >= len {
  #|      true
  #|    } else if pred(array_get(xs, i)) {
  #|      r#loop(i + 1)
  #|    } else {
  #|      false
  #|    }
  #|  }
  #|  r#loop(0)
  #|}
  #|export let get = [T](xs: Array[T], index: Int) -> Option[T] {
  #|  if index < 0 || index >= array_length(xs) {
  #|    None
  #|  } else {
  #|    Some(array_get(xs, index))
  #|  }
  #|}
  #|export let zip = [A, B](xs: Array[A], ys: Array[B]) -> Array[(A, B)] {
  #|  let len_x = array_length(xs)
  #|  let len_y = array_length(ys)
  #|  let len = if len_x < len_y {
  #|    len_x
  #|  } else {
  #|    len_y
  #|  }
  #|  do {
  #|    let acc = array_builder()
  #|    let rec r#loop = (i: Int) -> ArrayBuilder[(A, B)] {
  #|      if i >= len {
  #|        acc
  #|      } else {
  #|        do {
  #|          array_builder_push(acc, (array_get(xs, i), array_get(ys, i)))
  #|          r#loop(i + 1)
  #|        }
  #|      }
  #|    }
  #|    array_builder_freeze(r#loop(0))
  #|  }
  #|}
  #|export let find = [T](xs: Array[T], pred: (x: T) -> Bool) -> Option[T] {
  #|  let len = array_length(xs)
  #|  let rec r#loop = (i: Int) -> Option[T] {
  #|    if i >= len {
  #|      None
  #|    } else {
  #|      let value = array_get(xs, i)
  #|      if pred(value) {
  #|        Some(value)
  #|      } else {
  #|        r#loop(i + 1)
  #|      }
  #|    }
  #|  }
  #|  r#loop(0)
  #|}
  #|export let any = [T](xs: Array[T], pred: (x: T) -> Bool) -> Bool {
  #|  match find(xs, pred) {
  #|    Some(_) => true,
  #|    _ => false
  #|  }
  #|}
  #|export let fold = [A, B](xs: Array[A], init: B, f: (acc: B, x: A) -> B) -> B {
  #|  let len = array_length(xs)
  #|  let rec r#loop = (i: Int, acc: B) -> B {
  #|    if i >= len {
  #|      acc
  #|    } else {
  #|      r#loop(i + 1, f(acc, array_get(xs, i)))
  #|    }
  #|  }
  #|  r#loop(0, init)
  #|}
  #|export let head = [T](xs: Array[T]) -> Option[T] {
  #|  get(xs, 0)
  #|}
  #|export let iter = [T, R](xs: Array[T], f: (x: T) -> R) -> Int {
  #|  let len = array_length(xs)
  #|  let rec r#loop = (i: Int) -> Int {
  #|    if i >= len {
  #|      i
  #|    } else {
  #|      do {
  #|        f(array_get(xs, i))
  #|        r#loop(i + 1)
  #|      }
  #|    }
  #|  }
  #|  r#loop(0)
  #|}
  #|export let last = [T](xs: Array[T]) -> Option[T] {
  #|  let len = array_length(xs)
  #|  if len == 0 {
  #|    None
  #|  } else {
  #|    Some(array_get(xs, len - 1))
  #|  }
  #|}
  #|export let slice = [T](xs: Array[T], start: Int, end: Int) -> Array[T] {
  #|  array_slice(xs, start, end)
  #|}
  #|export let append = [T](xs: Array[T], ys: Array[T]) -> Array[T] {
  #|  array_concat(xs, ys)
  #|}
  #|export let filter = [T](xs: Array[T], pred: (x: T) -> Bool) -> Array[T] {
  #|  let len = array_length(xs)
  #|  do {
  #|    let acc = array_builder()
  #|    let rec r#loop = (i: Int) -> ArrayBuilder[T] {
  #|      if i >= len {
  #|        acc
  #|      } else {
  #|        let value = array_get(xs, i)
  #|        if pred(value) {
  #|          do {
  #|            array_builder_push(acc, value)
  #|            r#loop(i + 1)
  #|          }
  #|        } else {
  #|          r#loop(i + 1)
  #|        }
  #|      }
  #|    }
  #|    array_builder_freeze(r#loop(0))
  #|  }
  #|}
  #|export let length = [T](xs: Array[T]) -> Int {
  #|  array_length(xs)
  #|}
  #|export let flatmap = [A, B](xs: Array[A], f: (x: A) -> Array[B]) -> Array[B] {
  #|  let len = array_length(xs)
  #|  do {
  #|    let acc = array_builder()
  #|    let rec push_chunk = (chunk: Array[B], j: Int, chunk_len: Int) -> ArrayBuilder[B] {
  #|      if j >= chunk_len {
  #|        acc
  #|      } else {
  #|        do {
  #|          array_builder_push(acc, array_get(chunk, j))
  #|          push_chunk(chunk, j + 1, chunk_len)
  #|        }
  #|      }
  #|    }
  #|    let rec r#loop = (i: Int) -> ArrayBuilder[B] {
  #|      if i >= len {
  #|        acc
  #|      } else {
  #|        let chunk = f(array_get(xs, i))
  #|        do {
  #|          push_chunk(chunk, 0, array_length(chunk))
  #|          r#loop(i + 1)
  #|        }
  #|      }
  #|    }
  #|    array_builder_freeze(r#loop(0))
  #|  }
  #|}
  #|export let reverse = [T](xs: Array[T]) -> Array[T] {
  #|  let len = array_length(xs)
  #|  do {
  #|    let acc = array_builder()
  #|    let rec r#loop = (i: Int) -> ArrayBuilder[T] {
  #|      if i < 0 {
  #|        acc
  #|      } else {
  #|        do {
  #|          array_builder_push(acc, array_get(xs, i))
  #|          r#loop(i - 1)
  #|        }
  #|      }
  #|    }
  #|    array_builder_freeze(r#loop(len - 1))
  #|  }
  #|}
  #|export let is_empty = [T](xs: Array[T]) -> Bool {
  #|  array_length(xs) == 0
  #|}
  #|export let array_map = [A, B](xs: Array[A], f: (x: A) -> B) -> Array[B] {
  #|  let len = array_length(xs)
  #|  do {
  #|    let acc = array_builder()
  #|    let rec r#loop = (i: Int) -> ArrayBuilder[B] {
  #|      if i >= len {
  #|        acc
  #|      } else {
  #|        do {
  #|          array_builder_push(acc, f(array_get(xs, i)))
  #|          r#loop(i + 1)
  #|        }
  #|      }
  #|    }
  #|    array_builder_freeze(r#loop(0))
  #|  }
  #|}

///|
pub let builtin_module_sources : Array[(String, String)] = [
  ("builtin/builtin_traits", builtin_builtin_traits_source),
  ("builtin/option", builtin_option_source),
  ("builtin/result", builtin_result_source),
  ("builtin/cmp", builtin_cmp_source),
  ("builtin/bool", builtin_bool_source),
  ("builtin/int", builtin_int_source),
  ("builtin/float", builtin_float_source),
  ("builtin/double", builtin_double_source),
  ("builtin/char", builtin_char_source),
  ("builtin/string", builtin_string_source),
  ("builtin/array", builtin_array_source),
]

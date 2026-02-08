// List - generic std API
// Ported from MoonBit core/list with xsh type-system constraints.

enum List[T] { Nil; Cons(T, List[T]) }

// Create empty list
let list_empty = [T]() -> List[T] { Nil }

// Create single-element list
let list_singleton = [T](x: T) -> List[T] { Cons(x, Nil) }

// Prepend element (cons)
let list_cons = [T](x: T, xs: List[T]) -> List[T] { Cons(x, xs) }

// Check if list is empty
let list_is_empty = [T](xs: List[T]) -> Bool {
  match xs { Nil => true, _ => false }
}

// Get head of list (returns Option)
let list_head = [T](xs: List[T]) -> Option[T] {
  match xs { Cons(h, _) => Some(h), _ => None }
}

// Get tail of list
let list_tail = [T](xs: List[T]) -> List[T] {
  match xs { Cons(_, t) => t, _ => Nil }
}

// Get length of list
let rec list_length = [T](xs: List[T]) -> Int {
  match xs {
    Nil => 0,
    Cons(_, t) => 1 + list_length(t)
  }
}

// Reverse list
let list_reverse = [T](xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(Nil, xs)
}

// Map over list
let list_map = [A, B](f: (x: A) -> B, xs: List[A]) -> List[B] {
  let rec go = (acc: List[B], rest: List[A]) -> List[B] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(f(h), acc), t)
    }
  }
  list_reverse(go(Nil, xs))
}

// Fold left
let list_fold = [A, B](f: (acc: B, x: A) -> B, init: B, xs: List[A]) -> B {
  let rec go = (acc: B, rest: List[A]) -> B {
    match rest {
      Nil => acc,
      Cons(h, t) => go(f(acc, h), t)
    }
  }
  go(init, xs)
}

// Filter list
let list_filter = [T](pred: (x: T) -> Bool, xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) =>
        if pred(h) { go(Cons(h, acc), t) }
        else { go(acc, t) }
    }
  }
  list_reverse(go(Nil, xs))
}

// Append two lists
let list_append = [T](xs: List[T], ys: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(ys, list_reverse(xs))
}

// Nth element (0-indexed)
let rec list_nth = [T](xs: List[T], n: Int) -> Option[T] {
  match xs {
    Nil => None,
    Cons(h, t) => if n == 0 { Some(h) } else { list_nth(t, n - 1) }
  }
}

// Take first n elements
let list_take = [T](n: Int, xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T], count: Int) -> List[T] {
    if count <= 0 { acc }
    else {
      match rest {
        Nil => acc,
        Cons(h, t) => go(Cons(h, acc), t, count - 1)
      }
    }
  }
  list_reverse(go(Nil, xs, n))
}

// Drop first n elements
let rec list_drop = [T](n: Int, xs: List[T]) -> List[T] {
  if n <= 0 { xs }
  else {
    match xs {
      Nil => Nil,
      Cons(_, t) => list_drop(n - 1, t)
    }
  }
}

// Membership with explicit comparator
let rec list_contains_by = [T](
  eq: (a: T, b: T) -> Bool,
  value: T,
  xs: List[T],
) -> Bool {
  match xs {
    Nil => false,
    Cons(h, t) => if eq(h, value) { true } else { list_contains_by(eq, value, t) }
  }
}

// Int-specialized helper kept for convenience
let list_sum = (xs: List[Int]) -> Int {
  list_fold((acc: Int, x: Int) -> Int { acc + x }, 0, xs)
}

// Helper to create list from values
let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Nil)))
}

let list_of5 = [T](a: T, b: T, c: T, d: T, e: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Cons(d, Cons(e, Nil)))))
}

// Tests
test "list_empty" {
  assert(list_is_empty(Nil))
  assert(not(list_is_empty(Cons(1, Nil))))
}

test "list_singleton" {
  let xs = list_singleton(42)
  assert(eq(list_length(xs), 1))
  match list_head(xs) {
    Some(v) => assert(eq(v, 42)),
    _ => assert(false)
  }
}

test "list_length" {
  assert(eq(list_length(Nil), 0))
  assert(eq(list_length(list_of3(1, 2, 3)), 3))
  assert(eq(list_length(list_of5(1, 2, 3, 4, 5)), 5))
}

test "list_reverse" {
  let xs = list_of3(1, 2, 3)
  let rev = list_reverse(xs)
  match list_head(rev) {
    Some(v) => assert(eq(v, 3)),
    _ => assert(false)
  }
}

test "list_map" {
  let xs = list_of3(1, 2, 3)
  let doubled = list_map((x: Int) -> Int { x * 2 }, xs)
  assert(eq(list_sum(doubled), 12))
}

test "list_map_generic" {
  let xs = list_of3("a", "bb", "ccc")
  let lengths = list_map((s: String) -> Int { string_length(s) }, xs)
  assert(eq(list_sum(lengths), 6))
}

test "list_fold" {
  let xs = list_of5(1, 2, 3, 4, 5)
  assert(eq(list_sum(xs), 15))
}

test "list_filter" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let evens = list_filter((x: Int) -> Bool { x % 2 == 0 }, xs)
  assert(eq(list_length(evens), 2))
  assert(eq(list_sum(evens), 6))
}

test "list_append" {
  let xs = list_of3(1, 2, 3)
  let ys = list_of3(4, 5, 6)
  let zs = list_append(xs, ys)
  assert(eq(list_length(zs), 6))
  assert(eq(list_sum(zs), 21))
}

test "list_nth" {
  let xs = list_of5(10, 20, 30, 40, 50)
  match list_nth(xs, 2) {
    Some(v) => assert(eq(v, 30)),
    _ => assert(false)
  }
  match list_nth(xs, 10) {
    None => assert(true),
    _ => assert(false)
  }
}

test "list_take" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let taken = list_take(3, xs)
  assert(eq(list_length(taken), 3))
  assert(eq(list_sum(taken), 6))
}

test "list_drop" {
  let xs = list_of5(1, 2, 3, 4, 5)
  let dropped = list_drop(2, xs)
  assert(eq(list_length(dropped), 3))
  assert(eq(list_sum(dropped), 12))
}

test "list_contains_by" {
  let xs = list_of3("a", "bb", "ccc")
  let eq_string = (a: String, b: String) -> Bool { string_equals(a, b) }
  assert(list_contains_by(eq_string, "bb", xs))
  assert(not(list_contains_by(eq_string, "z", xs)))
}

// Export all public functions and types
export {
  List, list_empty, list_singleton, list_cons, list_is_empty,
  list_head, list_tail, list_length, list_reverse, list_map,
  list_fold, list_sum, list_filter, list_append, list_nth,
  list_take, list_drop, list_contains_by, list_of3, list_of5
}

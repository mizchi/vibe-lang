// List - Cons list implementation for xsh
// Ported from MoonBit core/list

// Define List type as enum
enum List { Nil, Cons(Int, List) }

// Create empty list
let list_empty = () -> List { Nil }

// Create single-element list
let list_singleton = (x: Int) -> List { Cons(x, Nil) }

// Prepend element (cons)
let list_cons = (x: Int, xs: List) -> List { Cons(x, xs) }

// Check if list is empty
let list_is_empty = (xs: List) -> Bool {
  match xs { Nil => true, _ => false }
}

// Get head of list (returns Option)
let list_head = (xs: List) -> Option[Int] {
  match xs { Cons(h, _) => Some(h), _ => None }
}

// Get tail of list
let list_tail = (xs: List) -> List {
  match xs { Cons(_, t) => t, _ => Nil }
}

// Get length of list
let rec list_length = (xs: List) -> Int {
  match xs {
    Nil => 0,
    Cons(_, t) => 1 + list_length(t)
  }
}

// Reverse list
let list_reverse = (xs: List) -> List {
  let rec go = (acc: List, rest: List) -> List {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(Nil, xs)
}

// Map over list
let list_map = (f: (x: Int) -> Int, xs: List) -> List {
  let rec go = (acc: List, rest: List) -> List {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(f(h), acc), t)
    }
  }
  list_reverse(go(Nil, xs))
}

// Fold left
let list_fold = (f: (acc: Int, x: Int) -> Int, init: Int, xs: List) -> Int {
  let rec go = (acc: Int, rest: List) -> Int {
    match rest {
      Nil => acc,
      Cons(h, t) => go(f(acc, h), t)
    }
  }
  go(init, xs)
}

// Sum of list
let list_sum = (xs: List) -> Int {
  list_fold((acc: Int, x: Int) -> Int { acc + x }, 0, xs)
}

// Filter list
let list_filter = (pred: (x: Int) -> Bool, xs: List) -> List {
  let rec go = (acc: List, rest: List) -> List {
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
let list_append = (xs: List, ys: List) -> List {
  let rec go = (acc: List, rest: List) -> List {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(ys, list_reverse(xs))
}

// Nth element (0-indexed)
let rec list_nth = (xs: List, n: Int) -> Option[Int] {
  match xs {
    Nil => None,
    Cons(h, t) => if n == 0 { Some(h) } else { list_nth(t, n - 1) }
  }
}

// Take first n elements
let list_take = (n: Int, xs: List) -> List {
  let rec go = (acc: List, rest: List, count: Int) -> List {
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
let rec list_drop = (n: Int, xs: List) -> List {
  if n <= 0 { xs }
  else {
    match xs {
      Nil => Nil,
      Cons(_, t) => list_drop(n - 1, t)
    }
  }
}

// Helper to create list from values
let list_of3 = (a: Int, b: Int, c: Int) -> List {
  Cons(a, Cons(b, Cons(c, Nil)))
}

let list_of5 = (a: Int, b: Int, c: Int, d: Int, e: Int) -> List {
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

// Export all public functions and types
export {
  List, list_empty, list_singleton, list_cons, list_is_empty,
  list_head, list_tail, list_length, list_reverse, list_map,
  list_fold, list_sum, list_filter, list_append, list_nth,
  list_take, list_drop, list_of3, list_of5
}

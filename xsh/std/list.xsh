export enum List[T] {
  Nil;
  Cons(T, List[T])
}
export let rec list_nth = [T](xs: List[T], n: Int) -> Option[T] {
  match xs {
    Nil => None,
    Cons(h, t) => if n == 0 {
      Some(h)
    } else {
      list_nth(t, n - 1)
    }
  }
}
// Short names (optional): can be used with method-call desugar.
export let nth = [T](xs: List[T], n: Int) -> Option[T] {
  list_nth(xs, n)
}
export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Nil)))
}
export let of3 = [T](a: T, b: T, c: T) -> List[T] {
  list_of3(a, b, c)
}
// Membership with explicit comparator
export let list_of5 = [T](a: T, b: T, c: T, d: T, e: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Cons(d, Cons(e, Nil)))))
}
export let of5 = [T](a: T, b: T, c: T, d: T, e: T) -> List[T] {
  list_of5(a, b, c, d, e)
}
// Create empty list
export let list_cons = [T](x: T, xs: List[T]) -> List[T] {
  Cons(x, xs)
}
export let rec list_drop = [T](n: Int, xs: List[T]) -> List[T] {
  if n <= 0 {
    xs
  }
  else {
    match xs {
      Nil => Nil,
      Cons(_, t) => list_drop(n - 1, t)
    }
  }
}
export let drop = [T](xs: List[T], n: Int) -> List[T] {
  list_drop(n, xs)
}
export let list_fold = [A, B](f: (acc: B, x: A) -> B, init: B, xs: List[A]) -> B {
  let rec go = (acc: B, rest: List[A]) -> B {
    match rest {
      Nil => acc,
      Cons(h, t) => go(f(acc, h), t)
    }
  }
  go(init, xs)
}
// Sum int list
export let list_sum = (xs: List[Int]) -> Int {
  list_fold((acc: Int, x: Int) -> Int {
    acc + x
  }, 0, xs)
}
export let sum = (xs: List[Int]) -> Int {
  list_sum(xs)
}
// Get head of list (returns Option)
export let list_head = [T](xs: List[T]) -> Option[T] {
  match xs {
    Cons(h, _) => Some(h),
    _ => None
  }
}
export let head = [T](xs: List[T]) -> Option[T] {
  list_head(xs)
}
// Get tail of list
export let list_tail = [T](xs: List[T]) -> List[T] {
  match xs {
    Cons(_, t) => t,
    _ => Nil
  }
}
export let tail = [T](xs: List[T]) -> List[T] {
  list_tail(xs)
}
export let list_empty = [T]() -> List[T] {
  Nil
}
export let empty = [T]() -> List[T] {
  list_empty()
}
// List length
export let rec list_length = [T](xs: List[T]) -> Int {
  match xs {
    Nil => 0,
    Cons(_, t) => 1 + list_length(t)
  }
}
export let length = [T](xs: List[T]) -> Int {
  list_length(xs)
}
// Reverse list
export let list_reverse = [T](xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(Nil, xs)
}
export let reverse = [T](xs: List[T]) -> List[T] {
  list_reverse(xs)
}
export let list_map = [A, B](f: (x: A) -> B, xs: List[A]) -> List[B] {
  let rec go = (acc: List[B], rest: List[A]) -> List[B] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(f(h), acc), t)
    }
  }
  list_reverse(go(Nil, xs))
}
export let list_take = [T](n: Int, xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T], count: Int) -> List[T] {
    if count <= 0 {
      acc
    }
    else {
      match rest {
        Nil => acc,
        Cons(h, t) => go(Cons(h, acc), t, count - 1)
      }
    }
  }
  list_reverse(go(Nil, xs, n))
}
export let take = [T](xs: List[T], n: Int) -> List[T] {
  list_take(n, xs)
}
// Append lists
export let list_append = [T](xs: List[T], ys: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(ys, list_reverse(xs))
}
// Short names (optional): can be used with method-call desugar.
export let append = [T](xs: List[T], ys: List[T]) -> List[T] {
  list_append(xs, ys)
}
export let list_filter = [T](pred: (x: T) -> Bool, xs: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) =>
      if pred(h) {
        go(Cons(h, acc), t)
      }
      else {
        go(acc, t)
      }
    }
  }
  list_reverse(go(Nil, xs))
}
export let filter = [T](xs: List[T], pred: (x: T) -> Bool) -> List[T] {
  list_filter(pred, xs)
}
// Check if list is empty
export let list_is_empty = [T](xs: List[T]) -> Bool {
  match xs {
    Nil => true,
    _ => false
  }
}
export let is_empty = [T](xs: List[T]) -> Bool {
  list_is_empty(xs)
}
export let list_singleton = [T](x: T) -> List[T] {
  Cons(x, Nil)
}
export let singleton = [T](x: T) -> List[T] {
  list_singleton(x)
}
export let rec list_contains_by = [T](eq: (a: T, b: T) -> Bool, value: T, xs: List[T]) -> Bool {
  match xs {
    Nil => false,
    Cons(h, t) => if eq(h, value) {
      true
    } else {
      list_contains_by(eq, value, t)
    }
  }
}
export let contains_by = [T](xs: List[T], eq: (a: T, b: T) -> Bool, value: T) -> Bool {
  list_contains_by(eq, value, xs)
}
// Type member names: can be imported with `use <module-ref> { List }`
export let List::nth = [T](xs: List[T], n: Int) -> Option[T] {
  list_nth(xs, n)
}
export let List::sum = (xs: List[Int]) -> Int {
  list_sum(xs)
}
export let List::drop = [T](xs: List[T], n: Int) -> List[T] {
  list_drop(n, xs)
}
export let List::head = [T](xs: List[T]) -> Option[T] {
  list_head(xs)
}
export let List::tail = [T](xs: List[T]) -> List[T] {
  list_tail(xs)
}
export let List::take = [T](xs: List[T], n: Int) -> List[T] {
  list_take(n, xs)
}
export let List::append = [T](xs: List[T], ys: List[T]) -> List[T] {
  list_append(xs, ys)
}
export let List::filter = [T](xs: List[T], pred: (x: T) -> Bool) -> List[T] {
  list_filter(pred, xs)
}
export let List::length = [T](xs: List[T]) -> Int {
  list_length(xs)
}
// Helper to create list from values
export let List::reverse = [T](xs: List[T]) -> List[T] {
  list_reverse(xs)
}
export let List::is_empty = [T](xs: List[T]) -> Bool {
  list_is_empty(xs)
}
export let List::contains_by = [T](xs: List[T], eq: (a: T, b: T) -> Bool, value: T) -> Bool {
  list_contains_by(eq, value, xs)
}

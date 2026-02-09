// List - generic std API
// Ported from MoonBit core/list with xsh type-system constraints.

export enum List[T] { Nil; Cons(T, List[T]) }

// Create empty list
export let list_empty = [T]() -> List[T] { Nil }

// Create single-element list
export let list_singleton = [T](x: T) -> List[T] { Cons(x, Nil) }

// Prepend element (cons)
export let list_cons = [T](x: T, xs: List[T]) -> List[T] { Cons(x, xs) }

// Check if list is empty
export let list_is_empty = [T](xs: List[T]) -> Bool {
  match xs { Nil => true, _ => false }
}

// Get head of list (returns Option)
export let list_head = [T](xs: List[T]) -> Option[T] {
  match xs { Cons(h, _) => Some(h), _ => None }
}

// Get tail of list
export let list_tail = [T](xs: List[T]) -> List[T] {
  match xs { Cons(_, t) => t, _ => Nil }
}

// Get length of list
export let rec list_length = [T](xs: List[T]) -> Int {
  match xs {
    Nil => 0,
    Cons(_, t) => 1 + list_length(t)
  }
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

// Map over list
export let list_map = [A, B](f: (x: A) -> B, xs: List[A]) -> List[B] {
  let rec go = (acc: List[B], rest: List[A]) -> List[B] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(f(h), acc), t)
    }
  }
  list_reverse(go(Nil, xs))
}

// Fold left
export let list_fold = [A, B](f: (acc: B, x: A) -> B, init: B, xs: List[A]) -> B {
  let rec go = (acc: B, rest: List[A]) -> B {
    match rest {
      Nil => acc,
      Cons(h, t) => go(f(acc, h), t)
    }
  }
  go(init, xs)
}

// Filter list
export let list_filter = [T](pred: (x: T) -> Bool, xs: List[T]) -> List[T] {
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
export let list_append = [T](xs: List[T], ys: List[T]) -> List[T] {
  let rec go = (acc: List[T], rest: List[T]) -> List[T] {
    match rest {
      Nil => acc,
      Cons(h, t) => go(Cons(h, acc), t)
    }
  }
  go(ys, list_reverse(xs))
}

// Nth element (0-indexed)
export let rec list_nth = [T](xs: List[T], n: Int) -> Option[T] {
  match xs {
    Nil => None,
    Cons(h, t) => if n == 0 { Some(h) } else { list_nth(t, n - 1) }
  }
}

// Take first n elements
export let list_take = [T](n: Int, xs: List[T]) -> List[T] {
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
export let rec list_drop = [T](n: Int, xs: List[T]) -> List[T] {
  if n <= 0 { xs }
  else {
    match xs {
      Nil => Nil,
      Cons(_, t) => list_drop(n - 1, t)
    }
  }
}

// Membership with explicit comparator
export let rec list_contains_by = [T](
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
export let list_sum = (xs: List[Int]) -> Int {
  list_fold((acc: Int, x: Int) -> Int { acc + x }, 0, xs)
}

// Helper to create list from values
export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Nil)))
}

export let list_of5 = [T](a: T, b: T, c: T, d: T, e: T) -> List[T] {
  Cons(a, Cons(b, Cons(c, Cons(d, Cons(e, Nil)))))
}

enum List[T] { Nil; Cons(T, List[T]) }

let rec list_length = [T](xs: List[T]) -> Int {
  match xs {
    Nil => 0,
    Cons(_, t) => 1 + list_length(t)
  }
}

let ints = Cons(1, Cons(2, Cons(3, Nil)))
let strs = Cons("a", Cons("bb", Nil))

(list_length(ints), list_length(strs))

__DATA__
{"last":"(3, 2)"}

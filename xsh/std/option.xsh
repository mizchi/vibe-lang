export  trait Eq
 impl Eq for Int
 impl Eq for Float
 impl Eq for Double
 impl Eq for Bool
 impl Eq for String
 impl [
  T: Eq
  
]Eq for Option[T]


export let or = [
  T
](a: Option[T], b: Option[T]) -> Option[T] {
  match a {
    Some(_) => a,
    _ => b
  }
}
export let and = [
  A,
  B
](a: Option[A], b: Option[B]) -> Option[B] {
  match a {
    Some(_) => b,
    _ => None
  }
}
export let zip = [
  A,
  B
](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  match (a, b) {
    (Some(x),
    Some(y)) => Some((x,
    y)),
    _ => None
  }
}
export let equals = [
  T: Eq
](a: Option[T], b: Option[T]) -> Bool {
  match (a, b) {
    (Some(x),
    Some(y)) => x == y,
    (None,
    None) => true,
    _ => false
  }
}
export let filter = [
  T
](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  match opt {
    Some(v) => if pred(v) {
      Some(v)
    } else {
      None
    },
    _ => None
  }
}
// NOTE: `map` is currently a reserved keyword, so this short API uses `map_opt`.
export let map_or = [
  A,
  B
](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  match opt {
    Some(v) => f(v),
    _ => default
  }
}
export let flatmap = [
  A,
  B
](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  match opt {
    Some(v) => f(v),
    _ => None
  }
}
// NOTE: `map` is currently a reserved keyword, so this short API uses `map_opt`.
export let flatten = [
  T
](opt: Option[Option[T]]) -> Option[T] {
  match opt {
    Some(inner) => inner,
    _ => None
  }
}
export let is_some = [
  T
](opt: Option[T]) -> Bool {
  match opt {
    Some(_) => true,
    _ => false
  }
}
// Short names (preferred): use with method-call desugar, e.g. opt.unwrap_or(0)
export let is_none = [
  T
](opt: Option[T]) -> Bool {
  not(is_some(opt))
}
export let map_opt = [
  A,
  B
](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  match opt {
    Some(v) => Some(f(v)),
    _ => None
  }
}
export let or_else = [
  T
](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  match a {
    Some(_) => a,
    _ => fallback()
  }
}
export let zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  match zip(a, b) {
    Some((x,
    y)) => Some(x + y),
    _ => None
  }
}


// Short names (preferred): use with method-call desugar, e.g. opt.unwrap_or(0)
export let unwrap_or = [
  T
](opt: Option[T], default: T) -> T {
  match opt {
    Some(v) => v,
    _ => default
  }
}
export let Option::or = [
  T
](a: Option[T], b: Option[T]) -> Option[T] {
  or(a, b)
}
export let Option::and = [
  A,
  B
  
](a: Option[A], b: Option[B]) -> Option[B] {
  and(a, b)
}
export let Option::zip = [
  A,
  B
  
](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  zip(a, b)
}
export let Option::equals = [
  T: Eq
  
](a: Option[T], b: Option[T]) -> Bool {
  equals(a, b)
}
export let Option::filter = [
  T
](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  filter(opt, pred)
}
export let Option::map_or = [
  A,
  B
  
](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  map_or(opt, default, f)
}
export let unwrap_or_else = [
  T
](opt: Option[T], fallback: () -> T) -> T {
  match opt {
    Some(v) => v,
    _ => fallback()
  }
}


export let Option::flatmap = [
  A,
  B
  
](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  flatmap(opt, f)
}
export let Option::flatten = [
  T
](opt: Option[Option[T]]) -> Option[T] {
  flatten(opt)
}
export let Option::is_none = [
  T
](opt: Option[T]) -> Bool {
  is_none(opt)
}
export let Option::is_some = [
  T
](opt: Option[T]) -> Bool {
  is_some(opt)
}
export let Option::map_opt = [
  A,
  B
  
](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  map_opt(opt, f)
}
export let Option::or_else = [
  T
](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  or_else(a, fallback)
}
export let Option::zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  zip_sum(a, b)
}
export let Option::unwrap_or = [
  T
](opt: Option[T], default: T) -> T {
  unwrap_or(opt, default)
}
// Type member names: can be imported with `use <module-ref> { Option }`
export let Option::unwrap_or_else = [
  T
](opt: Option[T], fallback: () -> T) -> T {
  unwrap_or_else(opt, fallback)
}

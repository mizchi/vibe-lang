// Option utilities - trait/generic-oriented std API

export trait Eq
impl Eq for Int
impl Eq for Float
impl Eq for Double
impl Eq for Bool
impl Eq for String
impl [T: Eq] Eq for Option[T]

// Short names (preferred): use with method-call desugar, e.g. opt.unwrap_or(0)
export let is_some = [T](opt: Option[T]) -> Bool {
  match opt { Some(_) => true, _ => false }
}

export let is_none = [T](opt: Option[T]) -> Bool {
  not(is_some(opt))
}

export let unwrap_or = [T](opt: Option[T], default: T) -> T {
  match opt { Some(v) => v, _ => default }
}

export let unwrap_or_else = [T](opt: Option[T], fallback: () -> T) -> T {
  match opt { Some(v) => v, _ => fallback() }
}

// NOTE: `map` is currently a reserved keyword, so this short API uses `map_opt`.
export let map_opt = [A, B](opt: Option[A], f: (x: A) -> B) -> Option[B] {
  match opt { Some(v) => Some(f(v)), _ => None }
}

export let map_or = [A, B](opt: Option[A], default: B, f: (x: A) -> B) -> B {
  match opt { Some(v) => f(v), _ => default }
}

export let flatten = [T](opt: Option[Option[T]]) -> Option[T] {
  match opt { Some(inner) => inner, _ => None }
}

export let flatmap = [A, B](opt: Option[A], f: (x: A) -> Option[B]) -> Option[B] {
  match opt { Some(v) => f(v), _ => None }
}

export let filter = [T](opt: Option[T], pred: (x: T) -> Bool) -> Option[T] {
  match opt {
    Some(v) => if pred(v) { Some(v) } else { None },
    _ => None
  }
}

export let zip = [A, B](a: Option[A], b: Option[B]) -> Option[(A, B)] {
  match (a, b) {
    (Some(x), Some(y)) => Some((x, y)),
    _ => None
  }
}

export let and = [A, B](a: Option[A], b: Option[B]) -> Option[B] {
  match a { Some(_) => b, _ => None }
}

export let or = [T](a: Option[T], b: Option[T]) -> Option[T] {
  match a { Some(_) => a, _ => b }
}

export let or_else = [T](a: Option[T], fallback: () -> Option[T]) -> Option[T] {
  match a { Some(_) => a, _ => fallback() }
}

export let equals = [T: Eq](a: Option[T], b: Option[T]) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => x == y,
    (None, None) => true,
    _ => false
  }
}

export let zip_sum = (a: Option[Int], b: Option[Int]) -> Option[Int] {
  match zip(a, b) {
    Some((x, y)) => Some(x + y),
    _ => None
  }
}

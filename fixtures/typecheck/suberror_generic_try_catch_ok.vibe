suberror AppError(String);

let apply_safe = [T](f: (x: T) -> T with {Error}, x: T) -> T {
  try { f(x) } catch { x }
}

let boom = (x: Int) -> Int with {Error} {
  raise AppError("boom")
}

apply_safe(boom, 1)

let apply = [T](f: (x: T) -> T with {Error}, x: T) -> T {
  try { f(x) } catch { x }
}
let boom = (x: Int) -> Int with {Error} { x }
apply(boom, 1)

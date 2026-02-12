trait Eq
impl Eq for Int
let run = [T: Eq](x: T, f: (x: T) -> T with {Error}) -> T {
  try { f(x) } catch { x }
}
let bad = (x: String) -> String with {Error} { x }
run("s", bad)

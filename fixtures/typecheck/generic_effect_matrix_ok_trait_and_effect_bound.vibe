trait Eq
impl Eq for Int
let apply = [T: Eq](f: (x: T) -> T with {e}, x: T) -> T with {e} { f(x) }
let id_err = (x: Int) -> Int with {Error} { x }
let run = () -> Int {
  try { apply(id_err, 1) } catch { 0 }
}
run()

trait Eq
impl Eq for Int
let apply = [T: Eq](f: (x: T) -> T with {e}, x: T) -> T with {e} { f(x) }
let bad = (x: String) -> String with {Error} { x }
let run = () -> String { apply(bad, "s") }
run()

let apply = [T](f: (x: T) -> T with {e}, x: T) -> T with {e} { f(x) }
let risky = (x: Int) -> Int with {Error} { raise "boom" }
let run = () -> Int {
  try { apply(risky, 1) } catch { 0 }
}
run()

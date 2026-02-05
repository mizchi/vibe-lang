let pure_id = fn (x: Int) -> Int { x }

let effectful = fn (x: Int) -> Int with {Error} { x }
let fail = fn () -> Int with {Error} {
  assert(false)
  1
}

let handled = fn (x: Int) -> Int { try { effectful(x) } catch { 0 } }
let handled_error = try { fail() } catch { 99 }

let apply = fn (f: fn (x: Int) -> Int with {e}, x: Int) -> Int with {e} { f(x) }
let apply_ok = fn (x: Int) -> Int with {Error} { apply(effectful, x) }

let chain = fn (
  f: fn (x: Int) -> Int with {e},
  g: fn (x: Int) -> Int with {e},
  x: Int,
) -> Int with {e} { add(f(x), g(x)) }

let chain_ok = fn (x: Int) -> Int with {Error} { chain(effectful, effectful, x) }

let use_pure = fn (x: Int) -> Int { apply(pure_id, x) }

test "effects basic" { assert(eq(handled(3), 3)) }
test "effects catch" { assert(eq(handled_error, 99)) }
test "effects higher-order" { assert(eq(apply_ok(5), 5)) }
test "effects chain" { assert(eq(chain_ok(2), 4)) }
test "effects pure" { assert(eq(use_pure(4), 4)) }

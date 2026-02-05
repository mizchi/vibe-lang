let rec repeat = (s: String, n: Int) -> String {
  if eq(n, 0) {
    ""
  } else {
    string_concat(s, repeat(s, sub(n, 1)))
  }
}

let rec eq_loop = (a: String, b: String, i: Int, acc: Int) -> Int {
  if eq(i, 0) {
    acc
  } else {
    let ok = string_equals(a, b)
    let next = if ok { add(acc, 1) } else { acc }
    eq_loop(a, b, sub(i, 1), next)
  }
}

let base = repeat("abcd", 80)
let same = string_concat(base, "z")
let diff = string_concat(base, "y")
let a = eq_loop(same, same, 200, 0)
let b = eq_loop(same, diff, 200, 0)
add(a, b)

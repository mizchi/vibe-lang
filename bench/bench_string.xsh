let rec repeat = fn (s: String, n: Int) -> String {
  if eq(n, 0) {
    ""
  } else {
    string_concat(s, repeat(s, sub(n, 1)))
  }
}

let rec sum_codes = fn (s: String, i: Int, acc: Int) -> Int {
  if lt(i, string_length(s)) {
    let code = string_char_code_at(s, i)
    sum_codes(s, add(i, 1), add(acc, code))
  } else {
    acc
  }
}

let base = "abcdefghijklmnopqrstuvwxyz"
let s = repeat(base, 40)
let t = string_substring(s, 5, sub(string_length(s), 5))
let u = string_concat(t, s)
let sum = sum_codes(u, 0, 0)
let ok = string_equals(u, u)
if ok { sum } else { 0 }

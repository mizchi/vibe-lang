let rec repeat = (s: String, n: Int) -> String {
  if eq(n, 0) {
    ""
  } else {
    string_concat(s, repeat(s, sub(n, 1)))
  }
}

let rec concat_loop = (s: String, i: Int) -> String {
  if eq(i, 0) {
    s
  } else {
    concat_loop(string_concat(s, "x"), sub(i, 1))
  }
}

let base = repeat("abcdef", 40)
let out = concat_loop(base, 200)
string_length(out)

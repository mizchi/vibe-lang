let rec repeat = (s: String, n: Int) -> String {
  if eq(n, 0) {
    ""
  } else {
    string_concat(s, repeat(s, sub(n, 1)))
  }
}

let rec slice_loop = (s: String, i: Int, acc: Int) -> Int {
  if eq(i, 0) {
    acc
  } else {
    let len = string_length(s)
    let a = 5
    let b = sub(len, 5)
    let t = string_substring(s, a, b)
    slice_loop(s, sub(i, 1), add(acc, string_length(t)))
  }
}

let base = repeat("abcdefghijklmnopqrstuvwxyz", 20)
slice_loop(base, 200, 0)

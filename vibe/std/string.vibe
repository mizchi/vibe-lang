let string_drop = (s: String, n: Int) -> String {
  let len = string_length(s)
  if n <= 0 {
    s
  }
  else if n >= len {
    ""
  }
  else {
    string_substring(s, n, len)
  }
}
let string_head = (s: String) -> String {
  if string_length(s) == 0 {
    ""
  }
  else {
    string_substring(s, 0, 1)
  }
}
let string_init = (s: String) -> String {
  let len = string_length(s)
  if len <= 1 {
    ""
  }
  else {
    string_substring(s, 0, len - 1)
  }
}
let string_last = (s: String) -> String {
  let len = string_length(s)
  if len == 0 {
    ""
  }
  else {
    string_substring(s, len - 1, len)
  }
}
let string_tail = (s: String) -> String {
  let len = string_length(s)
  if len <= 1 {
    ""
  }
  else {
    string_substring(s, 1, len)
  }
}
let string_take = (s: String, n: Int) -> String {
  let len = string_length(s)
  if n <= 0 {
    ""
  }
  else if n >= len {
    s
  }
  else {
    string_substring(s, 0, n)
  }
}
let string_count = (s: String, sub: String) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len == 0 || sub_len > s_len {
    0
  }
  else {
    let rec go = (i: Int, acc: Int) -> Int {
      if i > s_len - sub_len {
        acc
      }
      else if string_equals(string_substring(s, i, i + sub_len), sub) {
        go(i + sub_len, acc + 1)
      } else {
        go(i + 1, acc)
      }
    }
    go(0, 0)
  }
}
let string_repeat = (s: String, n: Int) -> String {
  let rec go = (acc: String, chunk: String, count: Int) -> String {
    if count <= 0 {
      acc
    }
    else if count % 2 == 1 {
      go(string_concat(acc, chunk), string_concat(chunk, chunk), count / 2)
    } else {
      go(acc, string_concat(chunk, chunk), count / 2)
    }
  }
  go("", s, n)
}
export let from_char_code = (code: Int) -> String {
  string_from_char_code(code)
}
let string_compare = (a: String, b: String) -> Int {
  if string_equals(a, b) {
    0
  }
  else if a < b {
    -1
  }
  else {
    1
  }
}
let string_is_empty = (s: String) -> Bool {
  string_length(s) == 0
}
let string_build_pad = (pad_char: String, pad_len: Int) -> String {
  if pad_len <= 0 {
    ""
  }
  else {
    let unit_len = string_length(pad_char)
    if unit_len == 0 {
      ""
    }
    else {
      let repeats = (pad_len + unit_len - 1) / unit_len
      string_take(string_repeat(pad_char, repeats), pad_len)
    }
  }
}
let string_pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  let pad_len = target_len - len
  if pad_len <= 0 {
    s
  }
  else {
    let pad = string_build_pad(pad_char, pad_len)
    if string_length(pad) == 0 {
      s
    } else {
      string_concat(pad, s)
    }
  }
}
let string_ends_with = (s: String, suffix: String) -> Bool {
  let s_len = string_length(s)
  let suf_len = string_length(suffix)
  if suf_len > s_len {
    false
  }
  else {
    string_equals(string_substring(s, s_len - suf_len, s_len), suffix)
  }
}
let string_pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  let pad_len = target_len - len
  if pad_len <= 0 {
    s
  }
  else {
    let pad = string_build_pad(pad_char, pad_len)
    if string_length(pad) == 0 {
      s
    } else {
      string_concat(s, pad)
    }
  }
}
let string_starts_with = (s: String, prefix: String) -> Bool {
  let s_len = string_length(s)
  let p_len = string_length(prefix)
  if p_len > s_len {
    false
  }
  else {
    string_equals(string_substring(s, 0, p_len), prefix)
  }
}
let is_ascii_whitespace = (code: Int) -> Bool {
  code == 32 || code == 9 || code == 10 || code == 13
}
let string_trim_end = (s: String) -> String {
  let len = string_length(s)
  let rec find_end = (i: Int) -> Int {
    if i <= 0 {
      0
    }
    else {
      let code = string_char_code_at(s, i - 1)
      if is_ascii_whitespace(code) {
        find_end(i - 1)
      }
      else {
        i
      }
    }
  }
  let end = find_end(len)
  if end == len {
    s
  }
  else {
    string_substring(s, 0, end)
  }
}
let string_trim_start = (s: String) -> String {
  let len = string_length(s)
  let rec find_start = (i: Int) -> Int {
    if i >= len {
      len
    }
    else {
      let code = string_char_code_at(s, i)
      if is_ascii_whitespace(code) {
        find_start(i + 1)
      }
      else {
        i
      }
    }
  }
  let start = find_start(0)
  if start == 0 {
    s
  }
  else {
    string_substring(s, start, len)
  }
}
let string_trim = (s: String) -> String {
  string_trim_end(string_trim_start(s))
}
let string_is_blank = (s: String) -> Bool {
  string_is_empty(string_trim(s))
}
let string_equals_value = (a: String, b: String) -> Bool {
  string_equals(a, b)
}
let string_is_not_empty = (s: String) -> Bool {
  string_length(s) > 0
}
let string_index_of_from = (s: String, sub: String, start: Int) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if start < 0 {
    -1
  }
  else if sub_len == 0 {
    if start <= s_len {
      start
    } else {
      -1
    }
  }
  else if sub_len > s_len || start > s_len - sub_len {
    -1
  }
  else {
    let rec find = (i: Int) -> Int {
      if i > s_len - sub_len {
        -1
      }
      else if string_equals(string_substring(s, i, i + sub_len), sub) {
        i
      }
      else {
        find(i + 1)
      }
    }
    find(start)
  }
}
let string_contains = (s: String, sub: String) -> Bool {
  string_index_of_from(s, sub, 0) >= 0
}
let string_index_of = (s: String, sub: String) -> Int {
  string_index_of_from(s, sub, 0)
}
let string_replace = (s: String, pattern: String, replacement: String) -> String {
  let pat_len = string_length(pattern)
  if pat_len == 0 {
    s
  }
  else {
    let idx = string_index_of(s, pattern)
    if idx < 0 {
      s
    }
    else {
      let before = string_substring(s, 0, idx)
      let after = string_substring(s, idx + pat_len, string_length(s))
      string_concat(string_concat(before, replacement), after)
    }
  }
}
let string_replace_all = (s: String, pattern: String, replacement: String) -> String {
  let pat_len = string_length(pattern)
  let s_len = string_length(s)
  if pat_len == 0 || pat_len > s_len {
    s
  }
  else {
    let rec go = (start: Int, acc: String) -> String {
      let idx = string_index_of_from(s, pattern, start)
      if idx < 0 {
        let rest = string_substring(s, start, s_len)
        string_concat(acc, rest)
      } else {
        let before = string_substring(s, start, idx)
        let next_acc = string_concat(string_concat(acc, before), replacement)
        go(idx + pat_len, next_acc)
      }
    }
    go(0, "")
  }
}
let string_last_index_of = (s: String, sub: String) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len > s_len {
    -1
  }
  else if sub_len == 0 {
    s_len
  }
  else {
    let rec find = (i: Int) -> Int {
      if i < 0 {
        -1
      }
      else if string_equals(string_substring(s, i, i + sub_len), sub) {
        i
      }
      else {
        find(i - 1)
      }
    }
    find(s_len - sub_len)
  }
}
let string_utf8_length_value = (s: String) -> Int {
  string_utf8_length(s)
}
let string_utf16_length_value = (s: String) -> Int {
  string_utf16_length(s)
}
let string_unicode_length_value = (s: String) -> Int {
  string_unicode_length(s)
}
export let String::drop = (s: String, n: Int) -> String {
  string_drop(s, n)
}
export let String::head = (s: String) -> String {
  string_head(s)
}
export let String::init = (s: String) -> String {
  string_init(s)
}
export let String::last = (s: String) -> String {
  string_last(s)
}
export let String::tail = (s: String) -> String {
  string_tail(s)
}
export let String::take = (s: String, n: Int) -> String {
  string_take(s, n)
}
export let String::trim = (s: String) -> String {
  string_trim(s)
}
export let String::count = (s: String, sub: String) -> Int {
  string_count(s, sub)
}
export let String::equals = (a: String, b: String) -> Bool {
  string_equals_value(a, b)
}
export let String::repeat = (s: String, n: Int) -> String {
  string_repeat(s, n)
}
// Type member names: can be imported with `use <module-ref> { String }`
export let String::compare = (a: String, b: String) -> Int {
  string_compare(a, b)
}
export let String::replace = (s: String, pattern: String, replacement: String) -> String {
  string_replace(s, pattern, replacement)
}
export let String::contains = (s: String, sub: String) -> Bool {
  string_contains(s, sub)
}
export let String::index_of = (s: String, sub: String) -> Int {
  string_index_of(s, sub)
}
export let String::is_blank = (s: String) -> Bool {
  string_is_blank(s)
}
export let String::is_empty = (s: String) -> Bool {
  string_is_empty(s)
}
export let String::pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_left(s, target_len, pad_char)
}
export let String::trim_end = (s: String) -> String {
  string_trim_end(s)
}
export let String::ends_with = (s: String, suffix: String) -> Bool {
  string_ends_with(s, suffix)
}
export let String::pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_right(s, target_len, pad_char)
}
export let String::trim_start = (s: String) -> String {
  string_trim_start(s)
}
export let String::replace_all = (s: String, pattern: String, replacement: String) -> String {
  string_replace_all(s, pattern, replacement)
}
export let String::starts_with = (s: String, prefix: String) -> Bool {
  string_starts_with(s, prefix)
}
export let String::utf8_length = (s: String) -> Int {
  string_utf8_length_value(s)
}
export let String::is_not_empty = (s: String) -> Bool {
  string_is_not_empty(s)
}
export let String::utf16_length = (s: String) -> Int {
  string_utf16_length_value(s)
}
export let String::last_index_of = (s: String, sub: String) -> Int {
  string_last_index_of(s, sub)
}
export let String::unicode_length = (s: String) -> Int {
  string_unicode_length_value(s)
}

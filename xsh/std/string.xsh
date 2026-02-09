// String utilities - built on xsh string builtins

// Check if string is empty
let string_is_empty = (s: String) -> Bool {
  string_length(s) == 0
}

// Check if string is not empty
let string_is_not_empty = (s: String) -> Bool {
  string_length(s) > 0
}

// Get first character as string (or empty if empty)
let string_head = (s: String) -> String {
  if string_length(s) == 0 { "" }
  else { string_substring(s, 0, 1) }
}

// Get all but first character
let string_tail = (s: String) -> String {
  let len = string_length(s)
  if len <= 1 { "" }
  else { string_substring(s, 1, len) }
}

// Get last character as string
let string_last = (s: String) -> String {
  let len = string_length(s)
  if len == 0 { "" }
  else { string_substring(s, len - 1, len) }
}

// Get all but last character
let string_init = (s: String) -> String {
  let len = string_length(s)
  if len <= 1 { "" }
  else { string_substring(s, 0, len - 1) }
}

// Take first n characters
let string_take = (s: String, n: Int) -> String {
  let len = string_length(s)
  if n <= 0 { "" }
  else if n >= len { s }
  else { string_substring(s, 0, n) }
}

// Drop first n characters
let string_drop = (s: String, n: Int) -> String {
  let len = string_length(s)
  if n <= 0 { s }
  else if n >= len { "" }
  else { string_substring(s, n, len) }
}

// Repeat string n times
let string_repeat = (s: String, n: Int) -> String {
  let rec go = (acc: String, count: Int) -> String {
    if count <= 0 { acc }
    else { go(string_concat(acc, s), count - 1) }
  }
  go("", n)
}

// Pad left with a pad string to reach exact target length
let string_pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  if len >= target_len { s }
  else {
    let pad_len = target_len - len
    let unit_len = string_length(pad_char)
    if unit_len == 0 { s } else {
      let rec fill_pad = (acc: String) -> String {
        if string_length(acc) >= pad_len { acc }
        else { fill_pad(string_concat(acc, pad_char)) }
      }
      let pad = string_take(fill_pad(""), pad_len)
      string_concat(pad, s)
    }
  }
}

// Pad right with a pad string to reach exact target length
let string_pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  if len >= target_len { s }
  else {
    let pad_len = target_len - len
    let unit_len = string_length(pad_char)
    if unit_len == 0 { s } else {
      let rec fill_pad = (acc: String) -> String {
        if string_length(acc) >= pad_len { acc }
        else { fill_pad(string_concat(acc, pad_char)) }
      }
      let pad = string_take(fill_pad(""), pad_len)
      string_concat(s, pad)
    }
  }
}

// Check if string starts with prefix
let string_starts_with = (s: String, prefix: String) -> Bool {
  let s_len = string_length(s)
  let p_len = string_length(prefix)
  if p_len > s_len { false }
  else { string_equals(string_substring(s, 0, p_len), prefix) }
}

// Check if string ends with suffix
let string_ends_with = (s: String, suffix: String) -> Bool {
  let s_len = string_length(s)
  let suf_len = string_length(suffix)
  if suf_len > s_len { false }
  else { string_equals(string_substring(s, s_len - suf_len, s_len), suffix) }
}

// Check if string contains substring
let string_contains = (s: String, sub: String) -> Bool {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len > s_len { false }
  else if sub_len == 0 { true }
  else {
    let rec check = (i: Int) -> Bool {
      if i > s_len - sub_len { false }
      else if string_equals(string_substring(s, i, i + sub_len), sub) { true }
      else { check(i + 1) }
    }
    check(0)
  }
}

// Find index of substring (-1 if not found)
let string_index_of = (s: String, sub: String) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len > s_len { -1 }
  else if sub_len == 0 { 0 }
  else {
    let rec find = (i: Int) -> Int {
      if i > s_len - sub_len { -1 }
      else if string_equals(string_substring(s, i, i + sub_len), sub) { i }
      else { find(i + 1) }
    }
    find(0)
  }
}

// Find last index of substring (-1 if not found)
let string_last_index_of = (s: String, sub: String) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len > s_len { -1 }
  else if sub_len == 0 { s_len }
  else {
    let rec find = (i: Int) -> Int {
      if i < 0 { -1 }
      else if string_equals(string_substring(s, i, i + sub_len), sub) { i }
      else { find(i - 1) }
    }
    find(s_len - sub_len)
  }
}

// Count non-overlapping occurrences of substring
let string_count = (s: String, sub: String) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if sub_len == 0 || sub_len > s_len { 0 }
  else {
    let rec go = (i: Int, acc: Int) -> Int {
      if i > s_len - sub_len { acc }
      else if string_equals(string_substring(s, i, i + sub_len), sub) {
        go(i + sub_len, acc + 1)
      } else {
        go(i + 1, acc)
      }
    }
    go(0, 0)
  }
}

// Replace first occurrence of pattern with replacement
let string_replace = (s: String, pattern: String, replacement: String) -> String {
  let pat_len = string_length(pattern)
  if pat_len == 0 { s }
  else {
    let idx = string_index_of(s, pattern)
    if idx < 0 { s }
    else {
      let before = string_substring(s, 0, idx)
      let after = string_substring(s, idx + pat_len, string_length(s))
      string_concat(string_concat(before, replacement), after)
    }
  }
}

// Replace all non-overlapping occurrences of pattern with replacement
let string_replace_all = (s: String, pattern: String, replacement: String) -> String {
  let pat_len = string_length(pattern)
  let s_len = string_length(s)
  if pat_len == 0 || pat_len > s_len { s }
  else {
    let rec go = (start: Int, acc: String) -> String {
      let rest = string_substring(s, start, s_len)
      let idx = string_index_of(rest, pattern)
      if idx < 0 {
        string_concat(acc, rest)
      } else {
        let split = start + idx
        let before = string_substring(s, start, split)
        let next_acc = string_concat(string_concat(acc, before), replacement)
        go(split + pat_len, next_acc)
      }
    }
    go(0, "")
  }
}

// Short names (preferred): use with method-call desugar, e.g. "abc".contains("a")
let is_empty = (s: String) -> Bool { string_is_empty(s) }
let is_not_empty = (s: String) -> Bool { string_is_not_empty(s) }
let head = (s: String) -> String { string_head(s) }
let tail = (s: String) -> String { string_tail(s) }
let last = (s: String) -> String { string_last(s) }
let init = (s: String) -> String { string_init(s) }
let take = (s: String, n: Int) -> String { string_take(s, n) }
let drop = (s: String, n: Int) -> String { string_drop(s, n) }
let repeat = (s: String, n: Int) -> String { string_repeat(s, n) }
let pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_left(s, target_len, pad_char)
}
let pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_right(s, target_len, pad_char)
}
let starts_with = (s: String, prefix: String) -> Bool { string_starts_with(s, prefix) }
let ends_with = (s: String, suffix: String) -> Bool { string_ends_with(s, suffix) }
let contains = (s: String, sub: String) -> Bool { string_contains(s, sub) }
let index_of = (s: String, sub: String) -> Int { string_index_of(s, sub) }
let last_index_of = (s: String, sub: String) -> Int { string_last_index_of(s, sub) }
let count = (s: String, sub: String) -> Int { string_count(s, sub) }
let replace = (s: String, pattern: String, replacement: String) -> String {
  string_replace(s, pattern, replacement)
}
let replace_all = (s: String, pattern: String, replacement: String) -> String {
  string_replace_all(s, pattern, replacement)
}

// Tests
test "string_is_empty" {
  assert(string_is_empty(""))
  assert(not(string_is_empty("a")))
}

test "string_head_tail" {
  assert(string_equals(string_head("hello"), "h"))
  assert(string_equals(string_tail("hello"), "ello"))
  assert(string_equals(string_head(""), ""))
  assert(string_equals(string_tail(""), ""))
  assert(string_equals(string_tail("x"), ""))
}

test "string_last_init" {
  assert(string_equals(string_last("hello"), "o"))
  assert(string_equals(string_init("hello"), "hell"))
  assert(string_equals(string_last(""), ""))
  assert(string_equals(string_init("x"), ""))
}

test "string_take_drop" {
  assert(string_equals(string_take("hello", 3), "hel"))
  assert(string_equals(string_drop("hello", 2), "llo"))
  assert(string_equals(string_take("hi", 10), "hi"))
  assert(string_equals(string_drop("hi", 10), ""))
}

test "string_repeat" {
  assert(string_equals(string_repeat("ab", 3), "ababab"))
  assert(string_equals(string_repeat("x", 0), ""))
  assert(string_equals(string_repeat("", 5), ""))
}

test "string_pad" {
  assert(string_equals(string_pad_left("42", 5, "0"), "00042"))
  assert(string_equals(string_pad_right("hi", 5, "."), "hi..."))
  assert(string_equals(string_pad_left("hello", 3, "x"), "hello"))
  assert(string_equals(string_pad_left("a", 3, "xy"), "xya"))
  assert(string_equals(string_pad_right("a", 3, "xy"), "axy"))
}

test "string_starts_ends_with" {
  assert(string_starts_with("hello world", "hello"))
  assert(not(string_starts_with("hello", "world")))
  assert(string_ends_with("hello world", "world"))
  assert(not(string_ends_with("hello", "world")))
}

test "string_contains" {
  assert(string_contains("hello world", "lo wo"))
  assert(string_contains("abc", ""))
  assert(not(string_contains("abc", "xyz")))
}

test "string_index_of" {
  assert(eq(string_index_of("hello", "ll"), 2))
  assert(eq(string_index_of("hello", "x"), -1))
  assert(eq(string_index_of("hello", ""), 0))
}

test "string_replace" {
  assert(string_equals(string_replace("hello world", "world", "xsh"), "hello xsh"))
  assert(string_equals(string_replace("aaa", "a", "b"), "baa"))
  assert(string_equals(string_replace("hello", "x", "y"), "hello"))
  assert(string_equals(string_replace("abc", "", "X"), "abc"))
}

test "string_last_index_of" {
  assert(eq(string_last_index_of("hello", "l"), 3))
  assert(eq(string_last_index_of("hello", "x"), -1))
  assert(eq(string_last_index_of("hello", ""), 5))
}

test "string_count" {
  assert(eq(string_count("hello", "l"), 2))
  assert(eq(string_count("aaaa", "aa"), 2))
  assert(eq(string_count("abc", ""), 0))
}

test "string_replace_all" {
  assert(string_equals(string_replace_all("foo bar foo", "foo", "x"), "x bar x"))
  assert(string_equals(string_replace_all("aaaa", "aa", "b"), "bb"))
  assert(string_equals(string_replace_all("abc", "", "z"), "abc"))
}

test "string_short_aliases" {
  assert(is_empty(""))
  assert(contains("hello", "ell"))
  assert(string_equals(replace_all("foo foo", "foo", "x"), "x x"))
}

// Export all public functions
export {
  is_empty, is_not_empty, head, tail, last, init, take, drop, repeat,
  pad_left, pad_right, starts_with, ends_with, contains,
  index_of, last_index_of, count, replace, replace_all
}

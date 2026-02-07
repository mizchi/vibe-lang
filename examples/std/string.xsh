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

// Pad left with character to reach target length
let string_pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  if len >= target_len { s }
  else {
    let pad = string_repeat(pad_char, target_len - len)
    string_concat(pad, s)
  }
}

// Pad right with character to reach target length
let string_pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  if len >= target_len { s }
  else {
    let pad = string_repeat(pad_char, target_len - len)
    string_concat(s, pad)
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

// Replace first occurrence of pattern with replacement
let string_replace = (s: String, pattern: String, replacement: String) -> String {
  let idx = string_index_of(s, pattern)
  if idx < 0 { s }
  else {
    let before = string_substring(s, 0, idx)
    let after = string_substring(s, idx + string_length(pattern), string_length(s))
    string_concat(string_concat(before, replacement), after)
  }
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
}

// Export all public functions
export {
  string_is_empty, string_is_not_empty, string_head, string_tail,
  string_last, string_init, string_take, string_drop, string_repeat,
  string_pad_left, string_pad_right, string_starts_with, string_ends_with,
  string_contains, string_index_of, string_replace
}

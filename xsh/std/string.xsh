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

// Build a pad string with exact length.
let string_build_pad = (pad_char: String, pad_len: Int) -> String {
  if pad_len <= 0 { "" }
  else {
    let unit_len = string_length(pad_char)
    if unit_len == 0 { "" } else {
      let rec fill_pad = (acc: String) -> String {
        if string_length(acc) >= pad_len { acc }
        else { fill_pad(string_concat(acc, pad_char)) }
      }
      string_take(fill_pad(""), pad_len)
    }
  }
}

// Pad left with a pad string to reach exact target length
let string_pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  let pad_len = target_len - len
  if pad_len <= 0 { s }
  else {
    let pad = string_build_pad(pad_char, pad_len)
    if string_length(pad) == 0 { s } else { string_concat(pad, s) }
  }
}

// Pad right with a pad string to reach exact target length
let string_pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  let len = string_length(s)
  let pad_len = target_len - len
  if pad_len <= 0 { s }
  else {
    let pad = string_build_pad(pad_char, pad_len)
    if string_length(pad) == 0 { s } else { string_concat(s, pad) }
  }
}

// Find index of substring starting from `start` (-1 if not found).
let string_index_of_from = (s: String, sub: String, start: Int) -> Int {
  let s_len = string_length(s)
  let sub_len = string_length(sub)
  if start < 0 { -1 }
  else if sub_len == 0 {
    if start <= s_len { start } else { -1 }
  }
  else if sub_len > s_len || start > s_len - sub_len { -1 }
  else {
    let rec find = (i: Int) -> Int {
      if i > s_len - sub_len { -1 }
      else if string_equals(string_substring(s, i, i + sub_len), sub) { i }
      else { find(i + 1) }
    }
    find(start)
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
  string_index_of_from(s, sub, 0) >= 0
}

// Find index of substring (-1 if not found)
let string_index_of = (s: String, sub: String) -> Int {
  string_index_of_from(s, sub, 0)
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

// Short names (preferred): use with method-call desugar, e.g. "abc".contains("a")
export let is_empty = (s: String) -> Bool { string_is_empty(s) }
export let is_not_empty = (s: String) -> Bool { string_is_not_empty(s) }
export let head = (s: String) -> String { string_head(s) }
export let tail = (s: String) -> String { string_tail(s) }
export let last = (s: String) -> String { string_last(s) }
export let init = (s: String) -> String { string_init(s) }
export let take = (s: String, n: Int) -> String { string_take(s, n) }
export let drop = (s: String, n: Int) -> String { string_drop(s, n) }
export let repeat = (s: String, n: Int) -> String { string_repeat(s, n) }
export let pad_left = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_left(s, target_len, pad_char)
}
export let pad_right = (s: String, target_len: Int, pad_char: String) -> String {
  string_pad_right(s, target_len, pad_char)
}
export let starts_with = (s: String, prefix: String) -> Bool { string_starts_with(s, prefix) }
export let ends_with = (s: String, suffix: String) -> Bool { string_ends_with(s, suffix) }
export let contains = (s: String, sub: String) -> Bool { string_contains(s, sub) }
export let index_of = (s: String, sub: String) -> Int { string_index_of(s, sub) }
export let last_index_of = (s: String, sub: String) -> Int { string_last_index_of(s, sub) }
export let count = (s: String, sub: String) -> Int { string_count(s, sub) }
export let replace = (s: String, pattern: String, replacement: String) -> String {
  string_replace(s, pattern, replacement)
}
export let replace_all = (s: String, pattern: String, replacement: String) -> String {
  string_replace_all(s, pattern, replacement)
}

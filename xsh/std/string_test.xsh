import {
  String,
  is_empty,
  is_not_empty,
  utf8_length,
  utf16_length,
  unicode_length,
  is_blank,
  equals,
  compare,
  head,
  tail,
  last,
  init,
  take,
  drop,
  repeat,
  pad_left,
  pad_right,
  starts_with,
  ends_with,
  contains,
  index_of,
  last_index_of,
  count,
  replace,
  replace_all,
  trim,
  trim_start,
  trim_end
} from "./string.xsh"

let string_is_empty = is_empty
let string_is_not_empty = is_not_empty
let string_utf8_length = utf8_length
let string_utf16_length = utf16_length
let string_unicode_length = unicode_length
let string_is_blank = is_blank
let string_equals_std = equals
let string_compare = compare
let string_head = head
let string_tail = tail
let string_last = last
let string_init = init
let string_take = take
let string_drop = drop
let string_repeat = repeat
let string_pad_left = pad_left
let string_pad_right = pad_right
let string_starts_with = starts_with
let string_ends_with = ends_with
let string_contains = contains
let string_index_of = index_of
let string_last_index_of = last_index_of
let string_count = count
let string_replace = replace
let string_replace_all = replace_all
let string_trim = trim
let string_trim_start = trim_start
let string_trim_end = trim_end

test "string_is_empty" {
  assert(string_is_empty(""))
  assert(not(string_is_empty("a")))
}

test "string_equals_compare_blank" {
  assert(string_equals_std("abc", "abc"))
  assert(not(string_equals_std("abc", "ab")))
  assert(eq(string_compare("abc", "abc"), 0))
  assert(eq(string_compare("abc", "abd"), -1))
  assert(eq(string_compare("abd", "abc"), 1))
  assert(string_is_blank(""))
  assert(string_is_blank("    "))
  assert(not(string_is_blank(" a ")))
}

test "string_unicode_lengths" {
  assert(eq(string_utf8_length("abc"), 3))
  assert(eq(string_utf16_length("abc"), 3))
  assert(eq(string_unicode_length("abc"), 3))

  assert(eq(string_utf8_length("あ"), 3))
  assert(eq(string_utf16_length("あ"), 1))
  assert(eq(string_unicode_length("あ"), 1))

  assert(eq(string_utf8_length("😀"), 4))
  assert(eq(string_utf16_length("😀"), 2))
  assert(eq(string_unicode_length("😀"), 1))
}

test "string_type_members_and_method_style" {
  assert(String::is_empty(""))
  assert(not(String::is_empty("x")))
  assert("".is_empty())
  assert(not("x".is_empty()))
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

test "string_pad_edge_cases" {
  assert(string_equals(string_pad_left("ab", 5, ""), "ab"))
  assert(string_equals(string_pad_right("ab", 5, ""), "ab"))
  assert(string_equals(string_pad_left("ab", 0, "0"), "ab"))
  assert(string_equals(string_pad_right("ab", -1, "0"), "ab"))
}

test "string_starts_ends_with" {
  assert(string_starts_with("hello world", "hello"))
  assert(not(string_starts_with("hello", "world")))
  assert(string_ends_with("hello world", "world"))
  assert(not(string_ends_with("hello", "world")))
}

test "string_starts_ends_with_empty" {
  assert(string_starts_with("abc", ""))
  assert(string_ends_with("abc", ""))
  assert(string_starts_with("", ""))
  assert(string_ends_with("", ""))
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
  assert(string_equals(string_replace_all("ababa", "aba", "x"), "xba"))
}

test "string_short_aliases" {
  assert(is_empty(""))
  assert(contains("hello", "ell"))
  assert(string_equals(replace_all("foo foo", "foo", "x"), "x x"))
}

test "string_trim" {
  assert(string_equals(string_trim("  hello  "), "hello"))
  assert(string_equals(string_trim_start("   hi"), "hi"))
  assert(string_equals(string_trim_end("hi   "), "hi"))
}

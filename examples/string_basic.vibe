let s = string_concat("he", "llo")
let sub = string_substring(s, 1, 4)
let len = string_length(sub)
let code = string_char_code_at(sub, 0)
let ok = string_equals(sub, "ell")
test "string length" { assert(eq(len, 3)) }
test "string equals" { assert(ok) }
test "string code" { assert(eq(code, 'e')) }
test "string substring" { assert(string_equals(sub, "ell")) }
test "string_split" {
  let parts = string_split("a,b,c", ",")
  assert(eq(array_length(parts), 3))
  assert(string_equals(array_get(parts, 0), "a"))
  assert(string_equals(array_get(parts, 2), "c"))
}
test "string_index_of" {
  assert(eq(string_index_of("hello", "ll"), 2))
  assert(eq(string_index_of("hello", "xyz"), -1))
}
test "string_contains" {
  assert(string_contains("hello world", "world"))
  assert(not(string_contains("hello", "xyz")))
}
test "string_trim" {
  let trimmed = string_trim("  hello  ")
  assert(string_equals(trimmed, "hello"))
}

let s = string_concat("he", "llo")
let sub = string_substring(s, 1, 4)
let len = string_length(sub)
let code = string_char_code_at(sub, 0)
let ok = string_equals(sub, "ell")
test "string length" { assert(eq(len, 3)) }
test "string equals" { assert(ok) }
test "string code" { assert(eq(code, 'e')) }
test "string substring" { assert(string_equals(sub, "ell")) }

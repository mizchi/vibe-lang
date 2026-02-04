let s = string_concat("he", "llo")
let sub = string_substring(s, 1, 4)
let len = string_length(sub)
let code = string_char_code_at(sub, 0)
let ok = string_equals(sub, "ell")
let bonus = if ok { 1 } else { 0 }
add(add(len, bonus), code)

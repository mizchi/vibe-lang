-- XS Standard Library - String Operations
-- 文字列操作のための関数群
-- Note: 現在の実装では基本的な文字列操作のみ

-- String predicates
let emptyString s = s = ""

-- String concatenation (using built-in concat)
let strAppend = String.concat

-- Join strings with separator
rec join sep strs = case strs of {
  [] -> "";
  [s] -> s;
  [h, ...t] -> String.concat h (String.concat sep (join sep t))
}

-- Repeat string n times
rec repeatString n s = 
  if n = 0 { "" }
  else { String.concat s (repeatString (n - 1) s) }

-- String comparison helpers
let strEq s1 s2 = s1 = s2
let strNeq s1 s2 = not (s1 = s2)
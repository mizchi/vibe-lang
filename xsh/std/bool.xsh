// Bool utilities - ported from MoonBit core/bool

// Convert bool to int (true=1, false=0)
export let bool_to_int = (b: Bool) -> Int {
  if b { 1 } else { 0 }
}

// Convert int to bool (0=false, else=true)
export let int_to_bool = (n: Int) -> Bool {
  n != 0
}

// Logical implication: a implies b
export let bool_implies = (a: Bool, b: Bool) -> Bool {
  if a { b } else { true }
}

// Exclusive or
export let bool_xor = (a: Bool, b: Bool) -> Bool {
  if a { not(b) } else { b }
}

// NAND (not and)
export let bool_nand = (a: Bool, b: Bool) -> Bool {
  not(a && b)
}

// NOR (not or)
export let bool_nor = (a: Bool, b: Bool) -> Bool {
  not(a || b)
}

// All predicates true
export let bool_all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  a && b && c
}

// Any predicate true
export let bool_any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  a || b || c
}

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

// Type member names: can be imported as `import { Bool }`
export let Bool::to_int = (b: Bool) -> Int {
  bool_to_int(b)
}

export let Bool::implies = (a: Bool, b: Bool) -> Bool {
  bool_implies(a, b)
}

export let Bool::xor = (a: Bool, b: Bool) -> Bool {
  bool_xor(a, b)
}

export let Bool::nand = (a: Bool, b: Bool) -> Bool {
  bool_nand(a, b)
}

export let Bool::nor = (a: Bool, b: Bool) -> Bool {
  bool_nor(a, b)
}

export let Bool::all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  bool_all3(a, b, c)
}

export let Bool::any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  bool_any3(a, b, c)
}

// Short names (preferred): use with method-call desugar, e.g. b.implies(other)
export let to_int = (b: Bool) -> Int {
  bool_to_int(b)
}

export let from_int = (n: Int) -> Bool {
  int_to_bool(n)
}

export let implies = (a: Bool, b: Bool) -> Bool {
  bool_implies(a, b)
}

export let xor = (a: Bool, b: Bool) -> Bool {
  bool_xor(a, b)
}

export let nand = (a: Bool, b: Bool) -> Bool {
  bool_nand(a, b)
}

export let nor = (a: Bool, b: Bool) -> Bool {
  bool_nor(a, b)
}

export let all3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  bool_all3(a, b, c)
}

export let any3 = (a: Bool, b: Bool, c: Bool) -> Bool {
  bool_any3(a, b, c)
}

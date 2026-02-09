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

// Tests
test "bool_to_int" {
  assert(eq(bool_to_int(true), 1))
  assert(eq(bool_to_int(false), 0))
}

test "int_to_bool" {
  assert(int_to_bool(1))
  assert(int_to_bool(42))
  assert(int_to_bool(-1))
  assert(not(int_to_bool(0)))
}

test "bool_implies" {
  // Truth table: F->F=T, F->T=T, T->F=F, T->T=T
  assert(bool_implies(false, false))
  assert(bool_implies(false, true))
  assert(not(bool_implies(true, false)))
  assert(bool_implies(true, true))
}

test "bool_xor" {
  assert(not(bool_xor(false, false)))
  assert(bool_xor(false, true))
  assert(bool_xor(true, false))
  assert(not(bool_xor(true, true)))
}

test "bool_nand" {
  assert(bool_nand(false, false))
  assert(bool_nand(false, true))
  assert(bool_nand(true, false))
  assert(not(bool_nand(true, true)))
}

test "bool_nor" {
  assert(bool_nor(false, false))
  assert(not(bool_nor(false, true)))
  assert(not(bool_nor(true, false)))
  assert(not(bool_nor(true, true)))
}

test "bool_all3" {
  assert(bool_all3(true, true, true))
  assert(not(bool_all3(true, true, false)))
  assert(not(bool_all3(false, false, false)))
}

test "bool_any3" {
  assert(bool_any3(true, false, false))
  assert(bool_any3(false, true, false))
  assert(not(bool_any3(false, false, false)))
}

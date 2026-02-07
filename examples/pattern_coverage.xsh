// Pattern coverage tests for WASM codegen
// Tests all Pat variants in both match expressions and let destructuring

// ============================================================
// 1. Wildcard pattern
// ============================================================
test "match_wildcard" {
  let x = 42
  let result = match x {
    _ => 1
  }
  assert(eq(result, 1))
}

// ============================================================
// 2. Bind pattern
// ============================================================
test "match_bind" {
  let x = 42
  let result = match x {
    n => n
  }
  assert(eq(result, 42))
}

// ============================================================
// 3. Ctor pattern (with Option type)
// ============================================================
test "match_ctor_some" {
  let x = Some(10)
  let result = match x {
    Some(v) => v
    _ => 0
  }
  assert(eq(result, 10))
}

test "match_ctor_none" {
  let x = None
  let result = match x {
    Some(v) => v
    _ => 99
  }
  assert(eq(result, 99))
}

test "let_ctor_some" {
  let opt = Some(42)
  let Some(x) = opt
  assert(eq(x, 42))
}

test "match_ctor_nested" {
  let x = Some((1, 2))
  let result = match x {
    Some((a, b)) => a + b
    _ => 0
  }
  assert(eq(result, 3))
}

// ============================================================
// 4. Tuple pattern
// ============================================================
test "match_tuple" {
  let t = (1, 2, 3)
  let result = match t {
    (a, b, c) => a + b + c
    _ => 0
  }
  assert(eq(result, 6))
}

test "let_tuple" {
  let (a, b) = (10, 20)
  assert(eq(a + b, 30))
}

test "let_tuple_nested" {
  let (a, (b, c)) = (1, (2, 3))
  assert(eq(a + b + c, 6))
}

test "let_tuple_deep_nested" {
  let (a, (b, (c, d))) = (1, (2, (3, 4)))
  assert(eq(a + b + c + d, 10))
}

// ============================================================
// 5. Record pattern
// ============================================================
test "match_record" {
  let r = record { x: 10, y: 20 }
  let result = match r {
    record { x: a, y: b } => a + b
    _ => 0
  }
  assert(eq(result, 30))
}

test "let_record" {
  let record { x: a, y: b } = record { x: 5, y: 15 }
  assert(eq(a + b, 20))
}

test "let_record_nested_tuple" {
  let record { x: a, y: (b, c) } = record { x: 1, y: (2, 3) }
  assert(eq(a + b + c, 6))
}

// ============================================================
// 6. Int literal pattern
// ============================================================
test "match_int" {
  let x = 42
  let result = match x {
    0 => 0
    42 => 1
    _ => 2
  }
  assert(eq(result, 1))
}

test "match_int_negative" {
  let x = 0 - 5
  let result = match x {
    0 => 0
    _ => 1
  }
  assert(eq(result, 1))
}

// ============================================================
// 7. Float literal pattern
// ============================================================
test "match_float" {
  let x = 1.5f
  let result = match x {
    1.5f => 1
    2.5f => 2
    _ => 0
  }
  assert(eq(result, 1))
}

test "match_float_other" {
  let x = 3.0f
  let result = match x {
    1.5f => 1
    2.5f => 2
    _ => 0
  }
  assert(eq(result, 0))
}

// ============================================================
// 8. Double literal pattern
// ============================================================
test "match_double" {
  let x = 1.5
  let result = match x {
    1.5 => 1
    2.5 => 2
    _ => 0
  }
  assert(eq(result, 1))
}

test "match_double_other" {
  let x = 3.0
  let result = match x {
    1.5 => 1
    2.5 => 2
    _ => 0
  }
  assert(eq(result, 0))
}

// ============================================================
// 9. Bool literal pattern
// ============================================================
test "match_bool_true" {
  let x = true
  let result = match x {
    true => 1
    _ => 0
  }
  assert(eq(result, 1))
}

test "match_bool_false" {
  let x = false
  let result = match x {
    true => 1
    _ => 0
  }
  assert(eq(result, 0))
}

// ============================================================
// 10. String literal pattern
// ============================================================
test "match_string" {
  let s = "hello"
  let result = match s {
    "hello" => 1
    "world" => 2
    _ => 0
  }
  assert(eq(result, 1))
}

test "match_string_other" {
  let s = "foo"
  let result = match s {
    "hello" => 1
    "world" => 2
    _ => 0
  }
  assert(eq(result, 0))
}

// ============================================================
// 11. Or pattern
// ============================================================
test "match_or_int" {
  let x = 2
  let result = match x {
    1 | 2 | 3 => 100
    _ => 0
  }
  assert(eq(result, 100))
}

test "match_or_int_miss" {
  let x = 5
  let result = match x {
    1 | 2 | 3 => 100
    _ => 0
  }
  assert(eq(result, 0))
}

test "match_or_ctor" {
  let x = Some(5)
  let result = match x {
    Some(1) | Some(2) | Some(5) => 200
    _ => 0
  }
  assert(eq(result, 200))
}

// TODO: Bool or-pattern needs parser fix
// test "match_or_bool" {
//   let x = true
//   let result = match x {
//     true | false => 1
//   }
//   assert(eq(result, 1))
// }

// ============================================================
// Combined patterns
// ============================================================
test "combined_tuple_in_ctor" {
  let x = Some((10, 20))
  let result = match x {
    Some((a, b)) => a + b
    _ => 0
  }
  assert(eq(result, 30))
}

test "combined_record_in_ctor" {
  let x = Some(record { a: 1, b: 2 })
  let result = match x {
    Some(record { a: x, b: y }) => x + y
    _ => 0
  }
  assert(eq(result, 3))
}

test "combined_ctor_in_tuple" {
  let x = (Some(10), None)
  let result = match x {
    (Some(a), None) => a,
    (None, Some(b)) => b,
    _ => 0
  }
  assert(eq(result, 10))
}

test "let_combined_nested" {
  let Some((a, record { x: b, y: c })) = Some((1, record { x: 2, y: 3 }))
  assert(eq(a + b + c, 6))
}

// ============================================================
// Edge cases
// ============================================================
test "match_with_guard_style" {
  // Pattern followed by complex body
  let x = (1, 2)
  let result = match x {
    (a, b) => {
      let sum = a + b
      let product = a * b
      sum + product
    },
    _ => 0
  }
  assert(eq(result, 5))  // (1+2) + (1*2) = 5
}

test "nested_match" {
  let x = Some(42)
  let result = match x {
    Some(n) => match n {
      42 => 1,
      _ => 2
    },
    _ => 0
  }
  assert(eq(result, 1))
}

test "wildcard_in_tuple" {
  let (a, _, c) = (1, 2, 3)
  assert(eq(a + c, 4))
}

test "wildcard_in_record" {
  let record { x: a, y: _ } = record { x: 10, y: 20 }
  assert(eq(a, 10))
}

test "wildcard_in_ctor" {
  let Some(_) = Some(999)
  assert(eq(1, 1))
}

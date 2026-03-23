///|
/// Helper: type-check a script and return the environment (or fail)
fn wasm_type_check(script : String) -> TypeEnv raise {
  let ast = @parser.parse_ast(script)
  type_check(ast)
}

///|
/// Helper: normalize a type directly
fn wasm_normalize(name : String) -> @core.Type raise {
  let env = TypeEnv::new()
  normalize_type(env, @core.Type::Named(name~, args=[]))
}

// --- Type resolution (normalize_type level) ---

///|
test "wasm type: i64 normalizes to Named" {
  let ty = wasm_normalize("i64") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="i64", args=[]))
}

///|
test "wasm type: u8 normalizes to Named" {
  let ty = wasm_normalize("u8") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="u8", args=[]))
}

///|
test "wasm type: u32 normalizes to Named" {
  let ty = wasm_normalize("u32") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="u32", args=[]))
}

///|
test "wasm type: u64 normalizes to Named" {
  let ty = wasm_normalize("u64") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="u64", args=[]))
}

///|
test "wasm type: i16 normalizes to Named" {
  let ty = wasm_normalize("i16") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="i16", args=[]))
}

///|
test "wasm type: v128 normalizes to Named" {
  let ty = wasm_normalize("v128") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="v128", args=[]))
}

// --- Existing aliases ---

///|
test "wasm type: i32 aliases to Int" {
  let ty = wasm_normalize("i32") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Int)
}

///|
test "wasm type: f64 aliases to Double" {
  let ty = wasm_normalize("f64") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Double)
}

// --- Arithmetic with type annotation ---

///|
test "wasm type: i64 Add via generic function" {
  let _ = wasm_type_check("let add_i64 = (a: i64, b: i64) -> i64 { a + b }") catch {
    err => fail("i64 Add failed: " + err.to_string())
  }
}

///|
test "wasm type: u32 Sub via generic function" {
  let _ = wasm_type_check("let sub_u32 = (a: u32, b: u32) -> u32 { a - b }") catch {
    err => fail("u32 Sub failed: " + err.to_string())
  }
}

///|
test "wasm type: u8 Mul via generic function" {
  let _ = wasm_type_check("let mul_u8 = (a: u8, b: u8) -> u8 { a * b }") catch {
    err => fail("u8 Mul failed: " + err.to_string())
  }
}

///|
test "wasm type: u16 Div via generic function" {
  let _ = wasm_type_check("let div_u16 = (a: u16, b: u16) -> u16 { a / b }") catch {
    err => fail("u16 Div failed: " + err.to_string())
  }
}

///|
test "wasm type: u64 Eq via generic function" {
  let _ = wasm_type_check("let eq_u64 = (a: u64, b: u64) -> Bool { a == b }") catch {
    err => fail("u64 Eq failed: " + err.to_string())
  }
}

///|
test "wasm type: i16 Ord via generic function" {
  let _ = wasm_type_check("let lt_i16 = (a: i16, b: i16) -> Bool { a < b }") catch {
    err => fail("i16 Ord failed: " + err.to_string())
  }
}

// --- Type mismatch ---

///|
test "wasm type: i64 and u32 mismatch" {
  let result : Result[TypeEnv, Error] = try? wasm_type_check(
    "let f = (a: i64, b: u32) -> i64 { a + b }",
  )
  match result {
    Ok(_) => fail("expected type mismatch between i64 and u32")
    Err(_) => () // expected
  }
}

///|
test "wasm type: u8 and Int mismatch" {
  let result : Result[TypeEnv, Error] = try? wasm_type_check(
    "let f = (a: u8, b: Int) -> u8 { a + b }",
  )
  match result {
    Ok(_) => fail("expected type mismatch between u8 and Int")
    Err(_) => () // expected
  }
}

// --- Wasm ref types (existing) ---

///|
test "wasm type: anyref normalizes to Named" {
  let ty = wasm_normalize("anyref") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="anyref", args=[]))
}

///|
test "wasm type: funcref normalizes to Named" {
  let ty = wasm_normalize("funcref") catch { err => fail(err.to_string()) }
  assert_eq(ty, @core.Type::Named(name="funcref", args=[]))
}

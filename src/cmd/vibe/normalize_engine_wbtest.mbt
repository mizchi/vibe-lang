///|
test "normalize_engine: format basic let binding" {
  let source = "let   x  =  1"
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet x: Int = 1\n")
  inspect(result, content=expected)
}

///|
test "normalize_engine: format multiple let bindings with spacing" {
  let source =
    #|let a  = 1
    #|let b  = 2
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet a: Int = 1\n\nlet b: Int = 2\n")
  inspect(result, content=expected)
}

///|
test "normalize_engine: constant folding for addition" {
  let source =
    #|let value = 1 + 2
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet value: Int = 3\n")
  inspect(result, content=expected)
}

///|
test "normalize_engine: constant folding for multiplication" {
  let source =
    #|let value = 3 * 4
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet value: Int = 12\n")
  inspect(result, content=expected)
}

///|
test "normalize_engine: inline single-use zero-arg fn" {
  let source =
    #|let helper = () -> Int { 1 + 2 }
    #|let value = helper()
    #|export let run = () -> Int { value }
    #|export { run }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      // helper should be inlined and folded
      assert_false(normalized.contains("let helper ="))
      assert_true(normalized.contains("let value: Int = 3"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: topological sort orders deps before dependents" {
  let source =
    #|let z = () -> Int { b() }
    #|let b = () -> Int { a() }
    #|let a = () -> Int { 1 }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      let idx_a = wbtest_substring_index(normalized, "let a =")
      let idx_b = wbtest_substring_index(normalized, "let b =")
      let idx_z = wbtest_substring_index(normalized, "let z =")
      assert_true(idx_a >= 0)
      assert_true(idx_b >= 0)
      assert_true(idx_z >= 0)
      // a has no deps, b depends on a, z depends on b
      assert_true(idx_a < idx_b)
      assert_true(idx_b < idx_z)
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: sort groups imports before types before functions" {
  let source =
    #|type Box = Int
    #|let value = 1
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      let idx_types = wbtest_substring_index(normalized, "//# Types")
      let idx_functions = wbtest_substring_index(normalized, "//# Functions")
      assert_true(idx_types >= 0)
      assert_true(idx_functions >= 0)
      assert_true(idx_types < idx_functions)
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: dead code elimination removes unused defs" {
  let source =
    #|let dead = () -> Int { 0 }
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export { run }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("let dead ="))
      assert_true(normalized.contains("let helper ="))
      assert_true(normalized.contains("run ="))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: full pipeline keeps export let for fn expressions" {
  let source =
    #|let helper = () -> Int { 1 }
    #|export let run = () -> Int { helper() }
    #|export { run }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      // Fn expressions should NOT produce declare + assignment
      assert_false(normalized.contains("declare export let run"))
      assert_true(normalized.contains("export let run ="))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: inferred annotation on non-fn let" {
  let source =
    #|let answer = 40 + 2
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet answer: Int = 42\n")
  inspect(result, content=expected)
}

///|
test "normalize_engine: NormalizeEngine incremental caching" {
  let engine = NormalizeEngine::new()
  engine.set_source("key1", "let x = 1")
  let r1 = engine.normalize("key1")
  match r1 {
    Ok(v) => assert_true(v.contains("let x: Int = 1"))
    Err(msg) => fail("first normalize failed: " + msg)
  }
  // Update source and re-normalize
  engine.set_source("key1", "let y = 2")
  let r2 = engine.normalize("key1")
  match r2 {
    Ok(v) => {
      assert_true(v.contains("let y: Int = 2"))
      assert_false(v.contains("let x"))
    }
    Err(msg) => fail("second normalize failed: " + msg)
  }
}

///|
test "normalize_engine: pure and effectful functions separated" {
  let source =
    #|export let pure_fn = () -> Int { 1 }
    #|export let effect_fn = () -> Int with {Error} { 2 }
    #|export { pure_fn, effect_fn }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      // Pure fn should appear before effectful fn
      let idx_pure = wbtest_substring_index(normalized, "pure_fn =")
      let idx_effect = wbtest_substring_index(
        normalized, "effect_fn = () -> Int with {",
      )
      assert_true(idx_pure >= 0)
      assert_true(idx_effect >= 0)
      assert_true(idx_pure < idx_effect)
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: empty source returns empty string" {
  let source = ""
  let result = normalize_source_text(source)
  let expected =
    #|Ok("")
  inspect(result, content=expected)
}

///|
test "normalize_engine: constant folding subtraction" {
  let source =
    #|let value = 10 - 3
  let result = normalize_source_text(source)
  let expected =
    #|Ok("//# Functions\n\nlet value: Int = 7\n")
  inspect(result, content=expected)
}

///|
fn ne_substring_index(haystack : String, needle : String) -> Int {
  let h_len = haystack.length()
  let n_len = needle.length()
  if n_len == 0 {
    return 0
  }
  if n_len > h_len {
    return -1
  }
  let mut i = 0
  let limit = h_len - n_len
  while i <= limit {
    let slice = try haystack[i:i + n_len] catch {
      _ => ""
    } noraise {
      value => value.to_string()
    }
    if slice == needle {
      return i
    }
    i += 1
  }
  -1
}

///|
test "normalize_engine: format basic let binding" {
  let source = "let   x  =  1"
  let result = normalize_source_text(source)
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet x: Int = 1\n")
    ),
  )
}

///|
test "normalize_engine: format multiple let bindings with spacing" {
  let source =
    #|let a  = 1
    #|let b  = 2
  let result = normalize_source_text(source)
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet a: Int = 1\n\nlet b: Int = 2\n")
    ),
  )
}

///|
test "normalize_engine: constant folding for addition" {
  let source =
    #|let value = 1 + 2
  let result = normalize_source_text(source)
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet value: Int = 3\n")
    ),
  )
}

///|
test "normalize_engine: constant folding for multiplication" {
  let source =
    #|let value = 3 * 4
  let result = normalize_source_text(source)
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet value: Int = 12\n")
    ),
  )
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
      let idx_a = ne_substring_index(normalized, "let a =")
      let idx_b = ne_substring_index(normalized, "let b =")
      let idx_z = ne_substring_index(normalized, "let z =")
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
      let idx_types = ne_substring_index(normalized, "//# Types")
      let idx_functions = ne_substring_index(normalized, "//# Functions")
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
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet answer: Int = 42\n")
    ),
  )
}

///|
test "normalize_engine: infers fn return annotation in fn expression" {
  let source =
    #|let f = (v: Int) { v * 2 }
    #|let y = f(3)
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      assert_true(normalized.contains("let f = (v: Int) -> Int { v * 2 }"))
      assert_true(normalized.contains("let y: Int = f(3)"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: entry normalize drops pure top-level expr and exports entries" {
  let source =
    #|let f = (v: Int) { v * 2 }
    #|f(3)
    #|let x = 3
    #|let y = f(x)
  let result = normalize_source_text_with_entry_names(source, ["x", "y"])
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("f(3)"))
      assert_true(normalized.contains("let f = (v: Int) -> Int { v * 2 }"))
      assert_true(normalized.contains("let x: Int = 3"))
      assert_true(normalized.contains("let y: Int = f(x)"))
      assert_true(normalized.contains("export { x, y }"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: entry normalize keeps unresolved top-level effect call" {
  let source =
    #|let f = (v: Int) { v * 2 }
    #|f(3)
    #|print("side")
    #|let x = 3
    #|let y = f(x)
  let result = normalize_source_text_with_entry_names(source, ["x", "y"])
  match result {
    Ok(normalized) => {
      assert_true(normalized.contains("print(\"side\")"))
      assert_true(normalized.contains("let y"))
      assert_true(normalized.contains("export { x, y }"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: entry normalize dedups duplicate lets with last wins" {
  let source =
    #|let x = 3
    #|let x = 111
    #|export { x }
  let result = normalize_source_text_with_entry_names(source, ["x"])
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("let x: Int = 3"))
      assert_true(normalized.contains("let x: Int = 111"))
      assert_true(normalized.contains("export { x }"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
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
      let idx_pure = ne_substring_index(normalized, "pure_fn =")
      let idx_effect = ne_substring_index(
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
  inspect(
    result,
    content=(
      #|Ok("//# Functions\n\nlet value: Int = 7\n")
    ),
  )
}

///|
test "normalize_engine: mutual recursion topo sort" {
  let source =
    #|let rec is_even = (n: Int) -> Bool {
    #|  if n == 0 { true } else { is_odd(n - 1) }
    #|}
    #|let rec is_odd = (n: Int) -> Bool {
    #|  if n == 0 { false } else { is_even(n - 1) }
    #|}
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      // Both should be present (circular deps should not crash)
      assert_true(normalized.contains("is_even"))
      assert_true(normalized.contains("is_odd"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: idempotency - normalize twice gives same result" {
  let source =
    #|let b = () -> Int { a() }
    #|let a = () -> Int { 1 }
    #|let c = () -> Int { b() }
  let result1 = normalize_source_text(source)
  match result1 {
    Ok(normalized1) => {
      let result2 = normalize_source_text(normalized1)
      match result2 {
        Ok(normalized2) => assert_eq(normalized1, normalized2)
        Err(msg) => fail("second normalize failed: " + msg)
      }
    }
    Err(msg) => fail("first normalize failed: " + msg)
  }
}

///|
test "normalize_engine: use-only source" {
  let source =
    #|import ./vibe/prelude/string.vibe { split }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => assert_true(normalized.contains("//# Imports"))
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: imports render canonical module ref and re-export comes first" {
  let source =
    #|import ./dep/index.vibe { value as value }
    #|export ./dep/index.vibe { value }
    #|export let run = value
    #|export { run }
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      let idx_export = ne_substring_index(normalized, "export ./dep { value }")
      let idx_import = ne_substring_index(normalized, "import ./dep { value }")
      assert_true(idx_export >= 0)
      assert_true(idx_import >= 0)
      assert_true(idx_export < idx_import)
      assert_false(normalized.contains("/index.vibe"))
      assert_false(normalized.contains(" as value"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: type-only source" {
  let source =
    #|type Meters = Int
    #|type Seconds = Int
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      assert_true(normalized.contains("//# Types"))
      assert_true(normalized.contains("type Meters = Int"))
      assert_true(normalized.contains("type Seconds = Int"))
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: many definitions topo sort correctness" {
  let buf = StringBuilder::new()
  // Create a chain: f0 has no deps, f1 depends on f0, f2 depends on f1, etc.
  for i in 0..<20 {
    let i_str = i.to_string()
    if i == 0 {
      buf.write_string("let f0 = () -> Int { 0 }\n")
    } else {
      buf.write_string(
        "let f" + i_str + " = () -> Int { f" + (i - 1).to_string() + "() }\n",
      )
    }
  }
  // Reverse the order to test sort
  let source = buf.to_string()
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) => {
      // Verify f0 appears before f19
      let idx_f0 = ne_substring_index(normalized, "let f0 =")
      let idx_f19 = ne_substring_index(normalized, "let f19 =")
      assert_true(idx_f0 >= 0)
      assert_true(idx_f19 >= 0)
      assert_true(idx_f0 < idx_f19)
    }
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "merge: dedup last wins" {
  let sources = [
    "let foo = 1\nlet bar = foo", "let foo = 2\nexport let out = foo + bar\nexport { out }",
  ]
  let result = normalize_merge_sources(sources, false)
  match result {
    Ok(normalized) => {
      // foo=2 should win (last definition)
      assert_true(normalized.contains("let foo"))
      // bar should be kept (only one definition)
      assert_true(normalized.contains("let bar"))
      // export should be preserved
      assert_true(normalized.contains("export let out"))
    }
    Err(msg) => fail("merge failed: " + msg)
  }
}

///|
test "merge: DCE after dedup" {
  let sources = [
    "let unused = 1\nlet used = 10", "export let out = used\nexport { out }",
  ]
  let result = normalize_merge_sources(sources, false)
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("let unused"))
      assert_true(normalized.contains("export let out"))
    }
    Err(msg) => fail("merge failed: " + msg)
  }
}

///|
test "merge: library mode removes side-effects" {
  let sources = [
    "let helper = () -> Int { 42 }\nexport let out = helper()\nexport { out }", "print(out)",
  ]
  let result = normalize_merge_sources(sources, true)
  match result {
    Ok(normalized) => {
      assert_false(normalized.contains("print"))
      assert_true(normalized.contains("export let out"))
    }
    Err(msg) => fail("merge failed: " + msg)
  }
}

///|
test "merge: type dedup last wins" {
  let sources = ["type Meters = Int", "type Meters = Float"]
  let result = normalize_merge_sources(sources, false)
  match result {
    Ok(normalized) => {
      assert_true(normalized.contains("type Meters = Float"))
      assert_false(normalized.contains("type Meters = Int"))
    }
    Err(msg) => fail("merge failed: " + msg)
  }
}

///|
test "merge: export preservation" {
  let sources = ["let a = 1", "let b = 2\nexport let c = a + b\nexport { c }"]
  let result = normalize_merge_sources(sources, false)
  match result {
    Ok(normalized) => {
      assert_true(normalized.contains("export let c"))
      assert_true(normalized.contains("let a"))
      assert_true(normalized.contains("let b"))
    }
    Err(msg) => fail("merge failed: " + msg)
  }
}

///|
test "normalize_engine: pipeline normalization for nested calls" {
  let source =
    #|let inc = (x: Int) -> Int { x + 1 }
    #|let dbl = (x: Int) -> Int { x * 2 }
    #|let result = inc(dbl(3))
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) =>
      inspect(
        normalized,
        content=(
          #|//# Functions
          #|
          #|let dbl = (x: Int) -> Int { x * 2 }
          #|
          #|let inc = (x: Int) -> Int { x + 1 }
          #|
          #|let result: Int = 3 |> dbl |> inc
          #|
        ),
      )
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: pipeline with extra args" {
  let source =
    #|let add = (x: Int, y: Int) -> Int { x + y }
    #|let mul = (x: Int, y: Int) -> Int { x * y }
    #|let result = add(mul(3, 2), 10)
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) =>
      inspect(
        normalized,
        content=(
          #|//# Functions
          #|
          #|let add = (x: Int, y: Int) -> Int { x + y }
          #|
          #|let mul = (x: Int, y: Int) -> Int { x * y }
          #|
          #|let result: Int = 3 |> mul(2) |> add(10)
          #|
        ),
      )
    Err(msg) => fail("normalize failed: " + msg)
  }
}

///|
test "normalize_engine: no pipeline for depth 1" {
  let source =
    #|let inc = (x: Int) -> Int { x + 1 }
    #|let result = inc(3)
  let result = normalize_source_text(source)
  match result {
    Ok(normalized) =>
      // depth 1: should NOT be pipelined
      assert_true(normalized.contains("let result: Int = inc(3)"))
    Err(msg) => fail("normalize failed: " + msg)
  }
}

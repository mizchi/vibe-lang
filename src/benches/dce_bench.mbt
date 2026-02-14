///|
/// DCE Benchmark: Compare WASM sizes with and without DCE

///|
struct DceBenchResult {
  name : String
  stmts_before : Int
  stmts_after : Int
  wasm_no_dce : Int?
  wasm_with_dce : Int?
  reduction_percent : Double?
} derive(Show)

///|
fn bench_dce(
  name : String,
  lib_source : String,
  main_source : String,
) -> DceBenchResult raise {
  let db = @runtime.VibeDb::new()
  if lib_source.length() > 0 {
    db.set_source("./lib.vibe", lib_source)
  }
  db.set_source("main", main_source)
  // Compile main module
  let compiled = try @runtime.compile_module(db, "main") catch {
    e => fail("[\{name}] compile error: \{e.to_string()}")
  } noraise {
    c => c
  }
  // Count statements before/after DCE
  let bundled_no_dce = @runtime.bundle_for_wasm_no_dce(db, "main", compiled.ast)
  let bundled_with_dce = @runtime.dce_module(bundled_no_dce)
  let stmts_before = bundled_no_dce.stmts.length()
  let stmts_after = bundled_with_dce.stmts.length()
  // Compile to WASM with and without DCE
  let wasm_no_dce : Int? = try
    @runtime.compile_module_wasm_no_dce(db, "main")
  catch {
    _ => None
  } noraise {
    wasm => Some(wasm.length())
  }
  let wasm_with_dce : Int? = try
    @runtime.compile_module_wasm(db, "main")
  catch {
    _ => None
  } noraise {
    wasm => Some(wasm.length())
  }
  // Calculate reduction
  let reduction_percent : Double? = match (wasm_no_dce, wasm_with_dce) {
    (Some(before), Some(after)) => {
      let diff = before - after
      Some(diff.to_double() / before.to_double() * 100.0)
    }
    _ => None
  }
  DceBenchResult::{
    name,
    stmts_before,
    stmts_after,
    wasm_no_dce,
    wasm_with_dce,
    reduction_percent,
  }
}

///|
/// Single module with many unused definitions (simulates bundled module)
let single_many_unused : String =
  #|// Large module with many unused definitions
  #|let unused_1 = 100
  #|let unused_2 = 200
  #|let unused_3 = 300
  #|let unused_4 = 400
  #|let unused_5 = 500
  #|let unused_6 = 600
  #|let unused_7 = 700
  #|let unused_8 = 800
  #|let unused_9 = 900
  #|let unused_10 = 1000
  #|let unused_fn_1 = (x: Int) -> Int { x * 2 }
  #|let unused_fn_2 = (x: Int) -> Int { x * 3 }
  #|let unused_fn_3 = (x: Int) -> Int { x * 4 }
  #|let unused_fn_4 = (x: Int) -> Int { x * 5 }
  #|let unused_fn_5 = (x: Int) -> Int { x * 6 }
  #|let helper = (x: Int) -> Int { x + 1 }
  #|let used_fn = (x: Int) -> Int { helper(x) }
  #|used_fn(42)

///|
test "bench: dce.many_unused" {
  let result = bench_dce("many_unused", "", single_many_unused)
  // Verify DCE reduces statement count significantly
  assert_true(result.stmts_after < result.stmts_before)
  // Print results for inspection
  inspect(
    result,
    content=(
      #|{name: "many_unused", stmts_before: 18, stmts_after: 3, wasm_no_dce: Some(531), wasm_with_dce: Some(326), reduction_percent: Some(38.60640301318267)}
    ),
  )
}

///|
/// Single module with internal unused definitions
let single_module_mixed : String =
  #|let unused_a = 1
  #|let unused_b = 2
  #|let unused_c = 3
  #|let helper = (x: Int) -> Int { x + 10 }
  #|let main_fn = (y: Int) -> Int { helper(y) }
  #|main_fn(5)

///|
test "bench: dce.single_module" {
  let result = bench_dce("single_module", "", single_module_mixed)
  assert_true(result.stmts_after < result.stmts_before)
  inspect(
    result,
    content=(
      #|{name: "single_module", stmts_before: 6, stmts_after: 3, wasm_no_dce: Some(337), wasm_with_dce: Some(325), reduction_percent: Some(3.5608308605341246)}
    ),
  )
}

///|
/// Deep dependency chain
let lib_chain : String =
  #|export let level1 = (x: Int) -> Int { x + 1 }
  #|export let level2 = (x: Int) -> Int { level1(x) + 1 }
  #|export let level3 = (x: Int) -> Int { level2(x) + 1 }
  #|export let level4 = (x: Int) -> Int { level3(x) + 1 }
  #|export let unused_chain = (x: Int) -> Int { x * 100 }

///|
let main_chain : String =
  #|use ./lib.vibe { level4 }
  #|level4(1)

///|
test "bench: dce.dependency_chain" {
  let result = bench_dce("dependency_chain", lib_chain, main_chain)
  // Should keep level1-4 but remove unused_chain
  assert_true(result.stmts_after < result.stmts_before)
  inspect(
    result,
    content=(
      #|{name: "dependency_chain", stmts_before: 7, stmts_after: 6, wasm_no_dce: Some(790), wasm_with_dce: Some(758), reduction_percent: Some(4.050632911392405)}
    ),
  )
}

///|
/// All definitions used (no reduction expected)
let lib_all_used : String =
  #|export let fn1 = (x: Int) -> Int { x + 1 }
  #|export let fn2 = (x: Int) -> Int { x + 2 }

///|
let main_all_used : String =
  #|use ./lib.vibe { fn1, fn2 }
  #|fn1(1) + fn2(2)

///|
test "bench: dce.all_used" {
  let result = bench_dce("all_used", lib_all_used, main_all_used)
  // No reduction when all definitions are used
  inspect(
    result,
    content=(
      #|{name: "all_used", stmts_before: 4, stmts_after: 4, wasm_no_dce: Some(169), wasm_with_dce: Some(169), reduction_percent: Some(0)}
    ),
  )
}

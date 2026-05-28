///|

///|
fn bytes_contains_ascii(bytes : Bytes, needle : String) -> Bool {
  let hay_len = bytes.length()
  let needle_len = needle.length()
  if needle_len == 0 {
    return true
  }
  let limit = hay_len - needle_len
  if limit < 0 {
    return false
  }
  for i in 0..<=limit {
    let mut ok = true
    for j in 0..<needle_len {
      if bytes[i + j].to_int() != needle[j].to_int() {
        ok = false
        break
      }
    }
    if ok {
      return true
    }
  }
  false
}

///|
fn name_matches_binding(name : String, binding_name : String) -> Bool {
  name == binding_name || name.has_prefix(binding_name + "$dep$")
}

///|
fn stmt_name_expr(stmt : @core.Stmt) -> (String, @core.Expr)? {
  match stmt {
    @core.Stmt::Let(name~, expr~, ..)
    | @core.Stmt::ExportLet(name~, expr~, ..)
    | @core.Stmt::InternalExportLet(name~, expr~, ..) => Some((name, expr))
    _ => None
  }
}

///|
fn runtime_compile_module_has_value_call(
  ast : @core.Module,
  binding_name : String,
  target_call : String,
) -> Bool {
  for stmt in ast.stmts {
    match stmt_name_expr(stmt) {
      Some((name, expr)) =>
        if name_matches_binding(name, binding_name) {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              return call_name == target_call
            _ => return false
          }
        }
      None => ()
    }
  }
  false
}

///|
fn runtime_compile_module_has_value_call_prefix(
  ast : @core.Module,
  binding_name : String,
  target_prefix : String,
) -> Bool {
  for stmt in ast.stmts {
    match stmt_name_expr(stmt) {
      Some((name, expr)) =>
        if name_matches_binding(name, binding_name) {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              return call_name.has_prefix(target_prefix)
            _ => return false
          }
        }
      None => ()
    }
  }
  false
}

///|
fn runtime_compile_module_fn_body_has_call(
  ast : @core.Module,
  binding_name : String,
  target_call : String,
) -> Bool {
  for stmt in ast.stmts {
    match stmt_name_expr(stmt) {
      Some((name, expr)) =>
        if name_matches_binding(name, binding_name) {
          match expr {
            @core.Expr::Fn(body~, ..) =>
              return module_to_sexp(body, {}).contains(target_call)
            _ => return false
          }
        }
      None => ()
    }
  }
  false
}

///|
fn runtime_compile_module_fn_body_has_call_pattern(
  ast : @core.Module,
  binding_name : String,
  target_prefix : String,
  target_suffix : String,
) -> Bool {
  for stmt in ast.stmts {
    match stmt_name_expr(stmt) {
      Some((name, expr)) =>
        if name_matches_binding(name, binding_name) {
          match expr {
            @core.Expr::Fn(body~, ..) => {
              let sexp = module_to_sexp(body, {})
              return sexp.contains(target_prefix) &&
                sexp.contains(target_suffix)
            }
            _ => return false
          }
        }
      None => ()
    }
  }
  false
}

///|
test "compile_module keeps parse error variant" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "let x =")
  let result : Result[CompiledModule, CompileError] = try? compile_module(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected parse error")
    Err(CompileError::Parse(_)) => ()
    Err(err) => fail("expected CompileError::Parse, got " + err.to_string())
  }
}

///|
test "compile_module cache reuses same key" {
  let db = @runtime.VibeDb::new()
  let before = compile_module_cache.val.length()
  let path = "cache-main-" + before.to_string()
  db.set_source(path, "let x = 1")
  let _ = compile_module(db, path)
  let after_first = compile_module_cache.val.length()
  let _ = compile_module(db, path)
  let after_second = compile_module_cache.val.length()
  assert_eq(after_first, before + 1)
  assert_eq(after_second, after_first)
}

///|
test "compile_module_wasm_with_opt_level_profiled reuses wasm artifact cache" {
  let db = @runtime.VibeDb::new()
  db.set_source("main", "let main = () -> Int { 1 + 2 }")
  let (bytes1, profile1) = compile_module_wasm_with_opt_level_profiled(
    db,
    "main",
    no_dce=true,
  )
  let (bytes2, profile2) = compile_module_wasm_with_opt_level_profiled(
    db,
    "main",
    no_dce=true,
  )
  assert_eq(bytes1, bytes2)
  assert_true(profile1.emit_us > 0)
  assert_eq(profile2.emit_us, 0)
  assert_eq(profile2.optimize_us, 0)
}

///|
test "compile_module_wasm_no_dce allows entry value shadowing prelude helper" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let add = (a: Int, b: Int) -> Int { a + b }
      #|let value = add(1, 2)
      #|value
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
  assert_eq(wasm_bytes[2], b'\x73')
  assert_eq(wasm_bytes[3], b'\x6d')
}

///|
test "let rec with new-style annotation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let rec f: (Int, Int) -> Int = (n, acc) -> {
      #|  if n <= 0 { acc } else f(n - 1, acc + n)
      #|}
      #|f(10, 0)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let rec new-style compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "let rec with old-style annotation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let rec f: (Int, Int) -> Int = (n: Int, acc: Int) -> Int {
      #|  if n <= 0 { acc } else f(n - 1, acc + n)
      #|}
      #|f(10, 0)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let rec old-style compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "compile_module_wasm_no_dce accepts mixed wrapper and direct type imports" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/core/types_impl.vibe",
    (
      #|export enum Type {
      #|  CtUnit
      #|}
      #|export enum TypeDef {
      #|  TDAlias(String, Type)
      #|}
    ),
  )
  db.set_source(
    "/project/types.vibe",
    (
      #|export ./core/types_impl.vibe {
      #|  Type, TypeDef
      #|}
      #|export {
      #|  Type, TypeDef
      #|}
    ),
  )
  db.set_source(
    "/project/use_wrapper.vibe",
    (
      #|import ./types.vibe {
      #|  Type
      #|}
      #|export let make_type = () -> Type {
      #|  CtUnit
      #|}
    ),
  )
  db.set_source(
    "/project/use_core.vibe",
    (
      #|import ./core/types_impl.vibe {
      #|  Type, TypeDef
      #|}
      #|export let make_type_def = () -> TypeDef {
      #|  TDAlias("dummy", CtUnit)
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./use_wrapper.vibe {
      #|  make_type
      #|}
      #|import ./use_core.vibe {
      #|  make_type_def
      #|}
      #|let _t = make_type()
      #|let _d = make_type_def()
    ),
  )
  let wasm = compile_module_wasm_no_dce(db, "/project/main.vibe") catch {
    e => fail(e.user_message())
  }
  assert_true(wasm.length() > 8)
}

///|
test "prepare_bundled_ast_for_codegen specializes imported iterable helpers by concrete root" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iterator.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iterator.vibe {
      #|  Iterator::fold
      #|}
      #|enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|let _keep = trio_of3(0, 1, 2)
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let value = Iterator::fold(trio_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled)
  let mut specialized_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("Iterator::fold$Trio") {
          specialized_name = Some(name)
        }
      _ => ()
    }
  }
  match specialized_name {
    Some(name) => {
      assert_true(
        runtime_compile_module_has_value_call(prepared, "value", name),
      )
      if !runtime_compile_module_fn_body_has_call(
          prepared, name, "Trio::iter_get",
        ) {
        fail(module_to_sexp(prepared, {}))
      }
    }
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "prepare_bundled_ast_for_codegen keeps mixed iterable fold roots distinct" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iterator.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] { Nil; Cons(T, List[T]) }
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] { Cons(a, Cons(b, Cons(c, Nil))) }
      #|let rec list_length = [T](xs: List[T]) -> Int {
      #|  match xs {
      #|    Nil => 0,
      #|    Cons(_, t) => 1 + list_length(t)
      #|  }
      #|}
      #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
      #|    Nil => list_iter_get(xs, index)
      #|  }
      #|}
      #|export let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
      #|export let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iterator.vibe {
      #|  Iterator::fold
      #|}
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let value_trio = Iterator::fold(trio_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
      #|let value_list = Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled)
  let mut trio_fold_name : String? = None
  let mut list_fold_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => {
        if name.has_prefix("Iterator::fold$Trio") {
          trio_fold_name = Some(name)
        }
        if name.has_prefix("Iterator::fold$List") {
          list_fold_name = Some(name)
        }
      }
      _ => ()
    }
  }
  match trio_fold_name {
    Some(name) => {
      assert_true(
        runtime_compile_module_has_value_call(prepared, "value_trio", name),
      )
      assert_true(
        runtime_compile_module_fn_body_has_call(
          prepared, name, "Trio::iter_get",
        ),
      )
    }
    None => fail(module_to_sexp(prepared, {}))
  }
  match list_fold_name {
    Some(name) => {
      assert_true(
        runtime_compile_module_has_value_call(prepared, "value_list", name),
      )
      assert_true(
        runtime_compile_module_fn_body_has_call(
          prepared, name, "List::iter_get",
        ),
      )
    }
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "prepare_bundled_ast_for_codegen keeps iterable helper roots distinct per parameter" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] { Nil; Cons(T, List[T]) }
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] { Cons(a, Cons(b, Cons(c, Nil))) }
      #|let rec list_length = [T](xs: List[T]) -> Int {
      #|  match xs {
      #|    Nil => 0,
      #|    Cons(_, t) => 1 + list_length(t)
      #|  }
      #|}
      #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
      #|    Nil => list_iter_get(xs, index)
      #|  }
      #|}
      #|export let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
      #|export let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let pair_sum = [X: Iterable, Y: Iterable](xs: X, ys: Y) -> Int {
      #|  let mut total = 0
      #|  let mut i = 0
      #|  let len_xs = xs|>iter_length
      #|  while i < len_xs {
      #|    total = total + (xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  let mut j = 0
      #|  let len_ys = ys|>iter_length
      #|  while j < len_ys {
      #|    total = total + (ys|>iter_get(j))
      #|    j = j + 1
      #|  }
      #|  total
      #|}
      #|let value = pair_sum(trio_of3(1, 2, 3), list_of3(4, 5, 6))
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled)
  let mut pair_sum_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("pair_sum$Trio") {
          pair_sum_name = Some(name)
        }
      _ => ()
    }
  }
  match pair_sum_name {
    Some(name) => {
      assert_true(
        runtime_compile_module_has_value_call(prepared, "value", name),
      )
      assert_true(
        runtime_compile_module_fn_body_has_call(
          prepared, name, "Trio::iter_get",
        ),
      )
      assert_true(
        runtime_compile_module_fn_body_has_call(
          prepared, name, "List::iter_get",
        ),
      )
    }
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "prepare_bundled_ast_for_codegen keeps array iterator root separate from local iterable prelude" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iterator.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iterator.vibe {
      #|  Iterator::fold
      #|}
      #|enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|let _iterator_test_trio_keep = trio_of3(0, 1, 2)
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let value = Iterator::fold([1, 2, 3, 4], 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled)
  let mut array_fold_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("Iterator::fold$Array") {
          array_fold_name = Some(name)
        }
      _ => ()
    }
  }
  match array_fold_name {
    Some(name) => {
      assert_true(
        runtime_compile_module_has_value_call(prepared, "value", name),
      )
      if runtime_compile_module_fn_body_has_call(
          prepared, name, "Trio::iter_get",
        ) ||
        runtime_compile_module_fn_body_has_call(prepared, name, "iter_get") ||
        runtime_compile_module_fn_body_has_call(prepared, name, "iter_length") ||
        !runtime_compile_module_fn_body_has_call(prepared, name, "Array::get") ||
        !runtime_compile_module_fn_body_has_call(
          prepared, name, "Array::length",
        ) {
        fail(module_to_sexp(prepared, {}))
      }
    }
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "bundle_for_codegen keeps array iterator root separate from imported plain iter helpers" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iterator.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] {
      #|  Nil;
      #|  Cons(T, List[T])
      #|}
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
      #|  Cons(a, Cons(b, Cons(c, Nil)))
      #|}
      #|export let iter_length = [T](_xs: List[T]) -> Int { 3 }
      #|export let rec iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(a, b) => if index == 0 { a } else { iter_get(b, index - 1) },
      #|    Nil => iter_get(xs, index)
      #|  }
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iterator.vibe {
      #|  Iterator::fold
      #|}
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|let _keep = list_of3(0, 1, 2)
      #|let value = Iterator::fold([1, 2, 3, 4], 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled) catch {
    err => fail(err.to_string())
  }
  let mut array_fold_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("Iterator::fold$Array") {
          array_fold_name = Some(name)
        }
      _ => ()
    }
  }
  match array_fold_name {
    Some(name) =>
      if runtime_compile_module_fn_body_has_call(prepared, name, "iter_get") ||
        runtime_compile_module_fn_body_has_call(prepared, name, "iter_length") ||
        !runtime_compile_module_fn_body_has_call(prepared, name, "Array::get") ||
        !runtime_compile_module_fn_body_has_call(
          prepared, name, "Array::length",
        ) {
        fail(module_to_sexp(prepared, {}))
      }
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "prepare_bundled_ast_for_codegen keeps imported iterable impls" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iter_mod.vibe",
    (
      #|export enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|export let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|export let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|export let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iter_mod.vibe {
      #|  Iterator::fold, trio_of3
      #|}
      #|let value = Iterator::fold(trio_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled) catch {
    err => fail(err.to_string())
  }
  assert_true(
    runtime_compile_module_has_value_call_prefix(
      prepared, "value", "Iterator::fold$Trio",
    ),
  )
}

///|
test "prepare_bundled_ast_for_codegen specializes imported iterator flatmap helpers" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/iterator.vibe",
    (
      #|export let Iterator::flatmap = [C: Iterable, A, B](xs: C, f: (x: A) -> Array[B]) -> Array[B] {
      #|  let len = xs|>iter_length
      #|  {
      #|    let acc = ArrayBuilder::new()
      #|    let mut i = 0
      #|    while i < len {
      #|      let chunk = f(xs|>iter_get(i))
      #|      let chunk_len = Array::length(chunk)
      #|      let mut j = 0
      #|      while j < chunk_len {
      #|        ArrayBuilder::push(acc, Array::get(chunk, j))
      #|        j = j + 1
      #|      }
      #|      i = i + 1
      #|    }
      #|    ArrayBuilder::freeze(acc)
      #|  }
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iterator.vibe {
      #|  Iterator::flatmap
      #|}
      #|enum Trio[T] {
      #|  Trio(T, T, T)
      #|}
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] {
      #|  Trio(a, b, c)
      #|}
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let value = Iterator::flatmap(trio_of3(1, 2, 3), (x: Int) -> Array[Int] { [x, x + 1] })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled)
  let mut flatmap_name : String? = None
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("Iterator::flatmap$Trio") {
          flatmap_name = Some(name)
        }
      _ => ()
    }
  }
  let mut has_trio_iter_get = false
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name.has_prefix("Trio::iter_get") {
          has_trio_iter_get = true
        }
      _ => ()
    }
  }
  assert_true(has_trio_iter_get)
  match flatmap_name {
    Some(name) =>
      assert_true(
        runtime_compile_module_fn_body_has_call_pattern(
          prepared, name, "Trio::iter_get", "",
        ),
      )
    None => fail(module_to_sexp(prepared, {}))
  }
}

///|
test "bundle_for_codegen keeps imported list iterator helper chain" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] {
      #|  Nil;
      #|  Cons(T, List[T])
      #|}
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
      #|  Cons(a, Cons(b, Cons(c, Nil)))
      #|}
      #|let rec list_length = [T](xs: List[T]) -> Int {
      #|  match xs {
      #|    Nil => 0,
      #|    Cons(_, t) => 1 + list_length(t)
      #|  }
      #|}
      #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
      #|    Nil => list_iter_get(xs, index)
      #|  }
      #|}
      #|export let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
      #|export let List::iter_length = [T](xs: List[T]) -> Int { list_length(xs) }
    ),
  )
  db.set_source(
    "/project/iter_mod.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iter_mod.vibe {
      #|  Iterator::fold
      #|}
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|let value = Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled) catch {
    err => fail(err.to_string())
  }
  let mut has_list_iter_get = false
  let mut has_list_length = false
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) => {
        if name.has_prefix("list_iter_get$") {
          has_list_iter_get = true
        }
        if name.has_prefix("list_length$") {
          has_list_length = true
        }
      }
      _ => ()
    }
  }
  assert_true(has_list_iter_get)
  assert_true(has_list_length)
}

///|
test "bundle_for_codegen specializes imported list iterator helper types" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] {
      #|  Nil;
      #|  Cons(T, List[T])
      #|}
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
      #|  Cons(a, Cons(b, Cons(c, Nil)))
      #|}
      #|let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
      #|    Nil => list_iter_get(xs, index)
      #|  }
      #|}
      #|export let List::iter_get = [T](xs: List[T], index: Int) -> T { list_iter_get(xs, index) }
      #|export let List::iter_length = [T](xs: List[T]) -> Int { 3 }
    ),
  )
  db.set_source(
    "/project/iter_mod.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iter_mod.vibe {
      #|  Iterator::fold
      #|}
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|let value = Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled) catch {
    err => fail(err.to_string())
  }
  let gc_bundled = bundle_for_wasm_no_dce(
    db,
    "/project/main.vibe",
    compiled.ast,
  )
  let gc_prepared = prepare_bundled_ast_for_codegen(gc_bundled) catch {
    err => fail(err.to_string())
  }
  let mut has_concrete_list_iter_get = false
  let mut has_gc_concrete_list_iter_get = false
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name == "list_iter_get$List|T=Int" {
          match expr {
            @core.Expr::Fn(params~, ret~, ..) =>
              if params.length() >= 1 &&
                params[0].ty ==
                @core.Type::Named(name="List", args=[@core.Type::Int]) &&
                ret == Some(@core.Type::Int) {
                has_concrete_list_iter_get = true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  for stmt in gc_prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name == "list_iter_get$List|T=Int" {
          match expr {
            @core.Expr::Fn(params~, ret~, ..) =>
              if params.length() >= 1 &&
                params[0].ty ==
                @core.Type::Named(name="List", args=[@core.Type::Int]) &&
                ret == Some(@core.Type::Int) {
                has_gc_concrete_list_iter_get = true
              }
            _ => ()
          }
        }
      _ => ()
    }
  }
  if !has_concrete_list_iter_get ||
    !has_gc_concrete_list_iter_get ||
    !runtime_compile_module_fn_body_has_call(
      prepared, "list_iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) ||
    !runtime_compile_module_fn_body_has_call(
      prepared, "List::iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) ||
    !runtime_compile_module_fn_body_has_call(
      gc_prepared, "list_iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) ||
    !runtime_compile_module_fn_body_has_call(
      gc_prepared, "List::iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) {
    fail(module_to_sexp(gc_prepared, {}))
  }
}

///|
test "bundle_for_codegen keeps prelude-style list iter helper recursion concrete" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/project/list_mod.vibe",
    (
      #|export enum List[T] {
      #|  Nil;
      #|  Cons(T, List[T])
      #|}
      #|impl [T] Iterable for List[T]
      #|export let list_of3 = [T](a: T, b: T, c: T) -> List[T] {
      #|  Cons(a, Cons(b, Cons(c, Nil)))
      #|}
      #|export let rec list_length = [T](xs: List[T]) -> Int {
      #|  match xs {
      #|    Nil => 0,
      #|    Cons(_, t) => 1 + list_length(t)
      #|  }
      #|}
      #|export let rec list_iter_get = [T](xs: List[T], index: Int) -> T {
      #|  match xs {
      #|    Cons(h, t) => if index == 0 { h } else { list_iter_get(t, index - 1) },
      #|    Nil => list_iter_get(xs, index)
      #|  }
      #|}
      #|export let iter_get = [T](xs: List[T], index: Int) -> T {
      #|  list_iter_get(xs, index)
      #|}
      #|export let iter_length = [T](xs: List[T]) -> Int {
      #|  list_length(xs)
      #|}
      #|export let List::iter_get = [T](xs: List[T], index: Int) -> T {
      #|  iter_get(xs, index)
      #|}
      #|export let List::iter_length = [T](xs: List[T]) -> Int {
      #|  iter_length(xs)
      #|}
    ),
  )
  db.set_source(
    "/project/iter_mod.vibe",
    (
      #|export let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
    ),
  )
  db.set_source(
    "/project/main.vibe",
    (
      #|import ./iter_mod.vibe {
      #|  Iterator::fold
      #|}
      #|import ./list_mod.vibe {
      #|  list_of3
      #|}
      #|let value = Iterator::fold(list_of3(1, 2, 3), 0, (acc: Int, x: Int) -> Int { acc + x })
    ),
  )
  let compiled = compile_module(db, "/project/main.vibe")
  let bundled = bundle_for_wasm_no_dce(db, "/project/main.vibe", compiled.ast)
  let prepared = prepare_bundled_ast_for_codegen(bundled) catch {
    err => fail(err.to_string())
  }
  if !runtime_compile_module_fn_body_has_call(
      prepared, "List::iter_get$List|T=Int", "iter_get$List|T=Int",
    ) ||
    !runtime_compile_module_fn_body_has_call(
      prepared, "iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) ||
    !runtime_compile_module_fn_body_has_call(
      prepared, "list_iter_get$List|T=Int", "list_iter_get$List|T=Int",
    ) {
    fail(module_to_sexp(prepared, {}))
  }
}

///|
test "compile_module_wasm_with_opt_level_profiled separates artifact cache by mode" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "cache_mode_probe", "let cache_mode_probe_unique = () -> Int { 1 + 2 }",
  )
  let (_, profile1) = compile_module_wasm_with_opt_level_profiled(
    db,
    "cache_mode_probe",
    no_dce=true,
  )
  let (_, profile2) = compile_module_wasm_with_opt_level_profiled(
    db,
    "cache_mode_probe",
    no_dce=true,
    library_mode=true,
  )
  assert_true(profile1.emit_us > 0)
  assert_true(profile2.emit_us > 0)
}

///|
test "check_incompatible_server_builtins detects Http::listen" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int with {Net} {
      #|  let listener = Http::listen(8080)
      #|  let req = Http::accept(listener)
      #|  Http::respond(req, 200, "", "ok")
      #|  0
      #|}
      #|let main = () -> Int with {Net} { run() }
      #|0
    ),
  )
  let compiled = compile_module(db, "main")
  let found = check_incompatible_server_builtins(compiled.ast)
  assert_true(found.contains("Http::listen"))
  assert_true(found.contains("Http::accept"))
  assert_true(found.contains("Http::respond"))
}

///|
test "check_incompatible_server_builtins passes handler pattern" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let handler = (method: String, url: String) -> Int {
      #|  if String::equals(method, "GET") { 200 } else { 405 }
      #|}
      #|handler("GET", "/")
    ),
  )
  let compiled = compile_module(db, "main")
  let found = check_incompatible_server_builtins(compiled.ast)
  assert_eq(found.length(), 0)
}

///|
test "component_string_lift_auto rejects server builtins" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let handler = (method: String, url: String) -> Int with {Net} {
      #|  let listener = Http::listen(8080)
      #|  let _ = Http::accept(listener)
      #|  200
      #|}
      #|let main = () -> Int with {Net} { handler("GET", "/") }
      #|0
    ),
  )
  let result : Result[Bytes, WasmCompileError] = try? compile_module_component_string_lift_auto(
    db, "main",
  )
  match result {
    Ok(_) => fail("expected error for incompatible builtins")
    Err(WasmCompileError::Optimize(msg)) =>
      assert_true(String::contains(msg, "incompatible"))
    Err(err) => fail("expected Optimize error, got " + err.to_string())
  }
}

///|
test "component_string_lift_auto kebab-cases snake_case export names" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|export let compile_cli_request = (method: String, url: String) -> Int {
      #|  if String::equals(method, url) { 1 } else { 0 }
      #|}
      #|compile_cli_request("GET", "GET")
    ),
  )
  let wasm = try compile_module_component_string_lift_auto(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    b => b
  }
  assert_true(bytes_contains_ascii(wasm, "compile-cli-request"))
}

///|
test "compile_module_wasm_with_opt_level_profiled returns wasm and stage timings" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let sum2 = (x : Int, y : Int) -> Int { x + y }
      #|sum2(20, 22)
    ),
  )
  let plain = try compile_module_wasm_with_opt_level(db, "main") catch {
    e => fail("compile error: " + e.to_string())
  } noraise {
    bytes => bytes
  }
  let (profiled, stage_profile) = try
    compile_module_wasm_with_opt_level_profiled(db, "main")
  catch {
    e => fail("profiled compile error: " + e.to_string())
  } noraise {
    value => value
  }
  assert_eq(profiled, plain)
  assert_true(stage_profile.module_us >= 0)
  assert_true(stage_profile.bundle_us >= 0)
  assert_true(stage_profile.emit_us >= 0)
  assert_true(stage_profile.optimize_us >= 0)
  assert_true(stage_profile.total_us >= 0)
}

///|
test "lower_top_level_tests_to_exprs wraps each test body in a function" {
  let source =
    #|let mut counter = 0
    #|test "a" {
    #|  counter = counter + 1
    #|}
    #|test "b" {
    #|  assert(eq(counter, 0))
    #|}
    #|0
  let ast = try @parser.parse_ast(source) catch {
    e => fail("parse error: " + e.to_string())
  } noraise {
    v => v
  }
  let lowered = lower_top_level_tests_to_exprs(ast)
  assert_eq(lowered.stmts.length(), 6)
  match lowered.stmts[0] {
    @core.Stmt::LetMut(name~, expr=@core.Expr::Int(value~, ..), ..) => {
      assert_eq(name, "counter")
      assert_eq(value, 0L)
    }
    _ => fail("expected mutable prelude to stay top-level")
  }
  match lowered.stmts[1] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ret~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      match ret {
        Some(@core.Type::Int) => ()
        _ => fail("expected wrapped test function to return Int")
      }
      assert_eq(body.stmts.length(), 2)
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
          assert_eq(value, 0L)
        _ => fail("expected wrapped test function to append explicit 0")
      }
    }
    _ => fail("expected first wrapper function")
  }
  match lowered.stmts[2] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected first wrapper invocation")
  }
  match lowered.stmts[3] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_1")
      assert_eq(body.stmts.length(), 2)
      match body.stmts[1] {
        @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
          assert_eq(value, 0L)
        _ => fail("expected second wrapped test function to append explicit 0")
      }
    }
    _ => fail("expected second wrapper function")
  }
  match lowered.stmts[4] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_1")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected second wrapper invocation")
  }
  match lowered.stmts[5] {
    @core.Stmt::Expr(expr=@core.Expr::Int(value~, ..), ..) =>
      assert_eq(value, 0L)
    _ => fail("expected non-test expr to stay top-level")
  }
}

///|
test "lower_top_level_tests_to_exprs keeps imports and helpers top-level" {
  let source =
    #|import ./helper.vibe { helper }
    #|let support = () -> Int { 1 }
    #|test "a" {
    #|  assert(helper(support()) == 2)
    #|}
  let ast = try @parser.parse_ast(source) catch {
    e => fail("parse error: " + e.to_string())
  } noraise {
    v => v
  }
  let lowered = lower_top_level_tests_to_exprs(ast)
  assert_eq(lowered.stmts.length(), 4)
  match lowered.stmts[0] {
    @core.Stmt::Import(..) => ()
    _ => fail("expected import to remain top-level")
  }
  match lowered.stmts[1] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(..), ..) =>
      assert_eq(name, "support")
    _ => fail("expected helper definition to remain top-level")
  }
  match lowered.stmts[2] {
    @core.Stmt::Let(name~, expr=@core.Expr::Fn(body~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(body.stmts.length(), 2)
      match body.stmts[0] {
        @core.Stmt::Expr(..) => ()
        _ => fail("expected original test body inside wrapper function")
      }
    }
    _ => fail("expected lowered test wrapper")
  }
  match lowered.stmts[3] {
    @core.Stmt::Expr(expr=@core.Expr::Call(name~, args~, ..), ..) => {
      assert_eq(name, "__vibe_cov_test_0")
      assert_eq(args.length(), 0)
    }
    _ => fail("expected wrapper invocation")
  }
}

///|
test "compile_module_wasm cross-directory transitive import" {
  // Simulates url_test.vibe: entry -> ./url/pattern.vibe -> ../regexp/index.vibe
  let db = @runtime.VibeDb::new()
  db.set_source(
    "/x/regexp/regexp.vibe", "export let make_regexp = (s: String) -> String { s }\n",
  )
  db.set_source(
    "/x/regexp/index.vibe", "import ./regexp.vibe { make_regexp }\nexport let compile_regexp = (s: String) -> String { make_regexp(s) }\n",
  )
  db.set_source(
    "/x/url/pattern.vibe", "import ../regexp { compile_regexp }\nexport let make_pattern = (s: String) -> String { compile_regexp(s) }\n",
  )
  db.set_source(
    "/x/url_test.vibe", "import ./url/pattern.vibe { make_pattern }\nlet main = () -> Int { let _ = make_pattern(\"x\")\n0 }\n",
  )
  let wasm_bytes = compile_module_wasm_with_opt_level(db, "/x/url_test.vibe") catch {
    e => fail("compile failed: " + e.user_message())
  }
  // WASM binary should start with magic number
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
  assert_eq(wasm_bytes[2], b'\x73')
  assert_eq(wasm_bytes[3], b'\x6d')
}

///|
test "compile_module_wasm with enable_rc produces valid WASM" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let x = (1, 2, 3)
    #|let y = x
    #|y
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  // Valid WASM magic number
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
  assert_eq(wasm_bytes[2], b'\x73')
  assert_eq(wasm_bytes[3], b'\x6d')
}

///|
test "compile_module_wasm with enable_rc analyzes function bodies" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let make = () -> (Int, Int, Int) { (1, 2, 3) }
    #|let x = make()
    #|x
  db.set_source("main", src)
  let wasm_rc = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_rc.length() > 8)
  assert_eq(wasm_rc[0], b'\x00')
  assert_eq(wasm_rc[1], b'\x61')
}

///|
test "compile_module_wasm with enable_rc produces larger binary than without" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let x = (1, 2, 3)
    #|x
  db.set_source("main", src)
  let wasm_no_rc = compile_module_wasm(db, "main")
  let wasm_rc = compile_module_wasm(db, "main", enable_rc=true)
  // RC version should be larger due to rc_init, rc_drop, etc.
  assert_true(wasm_rc.length() > wasm_no_rc.length())
}

///|
test "extract_func_bodies finds named function definitions" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let f = () -> Int { 1 }
    #|let g = () -> Int { 2 }
    #|let x = 42
    #|f()
  db.set_source("main", src)
  let compiled = compile_module(db, "main")
  let bodies = extract_func_bodies(compiled.ast)
  // Should find f and g but not x (not a function)
  assert_eq(bodies.length(), 2)
  assert_true(name_matches_binding(bodies[0].0, "f"))
  assert_true(name_matches_binding(bodies[1].0, "g"))
}

///|
test "extract_run_stmts excludes function definitions" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let f = () -> Int { 1 }
    #|let x = 42
    #|f()
  db.set_source("main", src)
  let compiled = compile_module(db, "main")
  let run_ast = extract_run_stmts(compiled.ast)
  // Function def excluded, only let x and f() call remain
  assert_eq(run_ast.stmts.length(), 2)
}

///|
test "compile_module_wasm with enable_rc handles mutable reassignment" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let run = () -> (Int, Int) {
    #|  let mut x = (1, 2)
    #|  x = (3, 4)
    #|  x
    #|}
    #|run()
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  // Valid WASM magic
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
  assert_eq(wasm_bytes[2], b'\x73')
  assert_eq(wasm_bytes[3], b'\x6d')
}

///|
test "compile_module_wasm with enable_rc handles function calling function" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let make = () -> (Int, Int) { (10, 20) }
    #|let use_it = (t: (Int, Int)) -> Int { t.0 }
    #|let x = make()
    #|use_it(x)
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
}

///|
test "compile_module_wasm with enable_rc handles array allocation" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let arr = [1, 2, 3]
    #|arr
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
}

///|
test "wasm_emit_options_with_rc stores per-function actions" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let f = () -> (Int, Int) {
    #|  let t = (1, 2)
    #|  t
    #|}
    #|let x = f()
    #|x
  db.set_source("main", src)
  let compiled = compile_module(db, "main")
  let (options, _desugared) = wasm_emit_options_with_rc(compiled.ast)
  // enable_rc should be true
  assert_true(options.enable_rc)
}

///|
test "compile_module_wasm with enable_rc handles nested tuple in function" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let make_nested = () -> ((Int, Int), (Int, Int)) {
    #|  let a = (1, 2)
    #|  let b = (3, 4)
    #|  (a, b)
    #|}
    #|let x = make_nested()
    #|x
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
}

///|
test "compile_module_wasm with enable_rc handles multiple functions" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let pair = () -> (Int, Int) { (1, 2) }
    #|let triple = () -> (Int, Int, Int) { (3, 4, 5) }
    #|let a = pair()
    #|let b = triple()
    #|a.0 + b.0
  db.set_source("main", src)
  let wasm_rc = compile_module_wasm(db, "main", enable_rc=true)
  let wasm_no_rc = compile_module_wasm(db, "main")
  // RC version should be larger
  assert_true(wasm_rc.length() > wasm_no_rc.length())
}

///|
test "compile_module_wasm with enable_rc handles if/else with tuple alloc" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let choose = (flag: Int) -> (Int, Int) {
    #|  if flag == 1 { (10, 20) } else { (30, 40) }
    #|}
    #|let r = choose(1)
    #|r.0
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
}

///|
test "compile_module_wasm with enable_rc handles string concatenation" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let greet = (name: String) -> String {
    #|  String::concat("Hello, ", name)
    #|}
    #|greet("world")
  db.set_source("main", src)
  let wasm_bytes = compile_module_wasm(db, "main", enable_rc=true)
  assert_true(wasm_bytes.length() > 8)
  assert_eq(wasm_bytes[0], b'\x00')
  assert_eq(wasm_bytes[1], b'\x61')
}

///|
test "extract_func_bodies skips non-function exports" {
  let db = @runtime.VibeDb::new()
  let src =
    #|export let handler = (x: Int) -> Int { x + 1 }
    #|let val = 42
    #|handler(val)
  db.set_source("main", src)
  let compiled = compile_module(db, "main")
  let bodies = extract_func_bodies(compiled.ast)
  // handler is a function (ExportLet+Fn), val is not
  assert_eq(bodies.length(), 1)
  assert_eq(bodies[0].0, "handler")
}

///|
test "extract_run_stmts preserves mutable bindings" {
  let db = @runtime.VibeDb::new()
  let src =
    #|let f = () -> Int { 1 }
    #|let x = 10
    #|let y = f() + x
    #|y
  db.set_source("main", src)
  let compiled = compile_module(db, "main")
  let run_ast = extract_run_stmts(compiled.ast)
  // f is excluded (function def), x/y/expr(y) remain
  assert_eq(run_ast.stmts.length(), 3)
}

///|
test "pattern match nested Option compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Option[Int]] = Some(Some(42))
      #|let result = match x {
      #|  Some(Some(v)) => v,
      #|  Some(None) => -1,
      #|  None => -2
      #|}
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested Option compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "match with guard compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let abs_val = (n: Int) -> Int {
      #|  match n {
      #|    x if x < 0 => 0 - x,
      #|    x => x
      #|  }
      #|}
      #|abs_val(-5) + abs_val(3)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("match guard compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "for-in with index compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let arr = [10, 20, 30]
      #|let result = for i, _x in arr { i }
      #|result[0]
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in index compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "pipe operator chain compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let double = (x: Int) -> Int { x * 2 }
      #|let add1 = (x: Int) -> Int { x + 1 }
      #|3 |> double |> add1
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("pipe chain compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "derive Eq enum compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Color { Red; Green; Blue } derive(Eq)
      #|let c = Color::Red
      #|if c == Color::Red { 1 } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("derive Eq enum compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "is expression compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(42)
      #|let result = if x is Some(v) { v } else { 0 }
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("is expression compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "loop with continue compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut result = 0
      #|  loop (i = 0, acc = 0) {
      #|    if i >= 10 {
      #|      result = acc
      #|      break
      #|    }
      #|    continue(i + 1, acc + i)
      #|  }
      #|  result
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("loop continue compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "HOF with closure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
      #|let double = (x: Int) -> Int { x * 2 }
      #|apply(double, 21)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("HOF closure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "tuple destructuring compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let (a, b, c) = (10, 20, 30)
      #|a + b + c
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("tuple destructure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "error effect handle compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let risky = (x: Int) -> Int with { Error } {
      #|  if x == 0 { throw("zero") }
      #|  x
      #|}
      #|let result = handle { risky(0) } with Error { Throw(_) => 99 }
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("error effect compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "or-pattern match compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 2
      #|match x {
      #|  1|2|3 => 10,
      #|  _ => 20
      #|}
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("or-pattern compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "while with break compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let arr = [10, 20, 30, 40, 50]
      #|  let mut found = -1
      #|  let mut i = 0
      #|  while i < 5 {
      #|    if arr[i] == 30 {
      #|      found = i
      #|      break
      #|    }
      #|    i += 1
      #|  }
      #|  found
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("while break compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "bitwise operators compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 0xFF & 0x0F
      #|let b = 0xF0 | 0x0F
      #|let c = 5 ^ 3
      #|let d = 1 << 8
      #|let e = 256 >> 4
      #|a + b + c + d + e
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("bitwise ops compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "string interpolation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 42
      #|let s = "val=\(x)"
      #|String::length(s)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("string interpolation compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "recursive enum compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Tree { Leaf(Int); Node(Tree, Tree) }
      #|let rec sum_tree = (t: Tree) -> Int {
      #|  match t {
      #|    Tree::Leaf(n) => n,
      #|    Tree::Node(l, r) => sum_tree(l) + sum_tree(r)
      #|  }
      #|}
      #|sum_tree(Tree::Node(Tree::Leaf(1), Tree::Node(Tree::Leaf(2), Tree::Leaf(3))))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("recursive enum compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "closure capturing variable compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let make_adder = (n: Int) -> (Int) -> Int {
      #|  (x: Int) -> Int { x + n }
      #|}
      #|let add5 = make_adder(5)
      #|add5(10)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("closure capture compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::map with lambda compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let arr = [1, 2, 3]
      #|let doubled = Array::map(arr, x -> x * 2)
      #|doubled[0]
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::map lambda compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::filter compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let arr = [1, 2, 3, 4, 5]
      #|let evens = Array::filter(arr, x -> x % 2 == 0)
      #|Array::length(evens)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::filter compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::fold compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let sum = Array::fold([1, 2, 3, 4], 0, _ + _)
      #|sum
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::fold compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested if-else chain compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let classify = (n: Int) -> String {
      #|  if n > 100 { "big" }
      #|  else if n > 10 { "medium" }
      #|  else if n > 0 { "small" }
      #|  else if n == 0 { "zero" }
      #|  else { "negative" }
      #|}
      #|String::length(classify(50))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested if-else compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "derive Eq struct comparison compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|struct Point { x: Int; y: Int } derive(Eq)
      #|let a = Point::{ x: 1, y: 2 }
      #|let b = Point::{ x: 1, y: 2 }
      #|if a == b { 1 } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("derive Eq struct compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "generic function instantiation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let identity = [T](x: T) -> T { x }
      #|let a = identity(42)
      #|let b = identity("hello")
      #|a + String::length(b)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("generic instantiation compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "string escape sequences compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "a\nb\tc"
      #|String::length(s)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("string escape compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "short-circuit and/or compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = true && false
      #|let b = false || true
      #|let c = true && true && false
      #|let d = false || false || true
      #|if a { 1 } else if b { 2 } else if c { 3 } else if d { 4 } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("short-circuit compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "map literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "a": 1, "b": 2 }
      #|m["a"]
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("map literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "tuple access compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let t = (10, 20, 30)
      #|t.0 + t.1 + t.2
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("tuple access compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "tuple destructure in function compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let swap = (a: Int, b: Int) -> (Int, Int) { (b, a) }
      #|let (x, y) = swap(1, 2)
      #|x + y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("tuple destructure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "closure capture mutable compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut x = 0
      #|  let inc = () -> Unit { x += 1 }
      #|  inc()
      #|  inc()
      #|  inc()
      #|  x
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("closure capture mutable compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "ArrayBuilder freeze compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let b = ArrayBuilder::new()
      #|ArrayBuilder::push(b, 10)
      #|ArrayBuilder::push(b, 20)
      #|let arr = ArrayBuilder::freeze(b)
      #|arr[0] + arr[1]
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("ArrayBuilder compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested enum match compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Expr { Num(Int); Add(Expr, Expr); Neg(Expr) }
      #|let rec eval = (e: Expr) -> Int {
      #|  match e {
      #|    Expr::Num(n) => n,
      #|    Expr::Add(a, b) => eval(a) + eval(b),
      #|    Expr::Neg(a) => 0 - eval(a)
      #|  }
      #|}
      #|eval(Expr::Add(Expr::Num(10), Expr::Neg(Expr::Num(3))))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested enum compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "string concat chain compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = "hello"
      #|let b = " "
      #|let c = "world"
      #|let result = String::concat(String::concat(a, b), c)
      #|String::length(result)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("string concat chain compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// Known failure: LetPatElse pattern bindings not registered in wasm codegen scope (#213)
test "let pat else compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(42)
      #|let Some(v) = x else { 0 }
      #|v
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let pat else compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "deeply nested function calls compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let add = (a: Int, b: Int) -> Int { a + b }
      #|let mul = (a: Int, b: Int) -> Int { a * b }
      #|mul(add(1, 2), add(3, 4))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested calls compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "record literal and field access compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let r = record { name: "vibe", version: 1 }
      #|r.name
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("record literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "struct definition and access compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|struct Point { x: Int; y: Int } derive(Eq)
      #|let p = Point::{ x: 10, y: 20 }
      #|p.x + p.y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("struct compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "type alias compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|type Pair = (Int, Int)
      #|let p: Pair = (1, 2)
      #|p.0 + p.1
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("type alias compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "char literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let c = 'A'
      #|c
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("char literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "double literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let d = 3.14
      #|d
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("double literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "float literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let f = 1.5f
      #|f
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("float literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "unary negation and not compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 10
      #|let y = -x
      #|let b = !true
      #|(y, b)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("unary ops compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "for-in collecting array compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3]
      #|let doubled = for x in xs { x * 2 }
      #|doubled
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in collect compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "placeholder lambda compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3]
      #|Array::map(xs, _ * 2)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("placeholder lambda compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "question mark operator compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let risky = (x: Int) -> Int with { Error } {
      #|  if x == 0 { throw("zero") }
      #|  x
      #|}
      #|let caller = () -> Int with { Error } {
      #|  let v = risky(1)?
      #|  v + 1
      #|}
      #|handle { caller() } with Error { Throw(_) => -1 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("? operator compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "user-defined effect with perform/resume compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|effect Logger {
      #|  Log(String) -> Unit
      #|}
      #|let greet = (name: String) -> String with { Logger } {
      #|  perform Logger::Log("hello " + name)
      #|  name
      #|}
      #|let run = () -> String {
      #|  let mut logged = ""
      #|  handle { greet("world") } with Logger {
      #|    Log(msg) => {
      #|      logged = msg
      #|      resume(())
      #|    };
      #|  }
      #|  logged
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("user effect compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "suberror typed error compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|suberror NotFound(String)
      #|let find = (key: String) -> Int with { Error } {
      #|  if key == "" { throw(NotFound("empty key")) }
      #|  42
      #|}
      #|handle { find("") } with Error { Throw(_) => -1 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("suberror compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "module block compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|module Math {
      #|  export let abs = (x: Int) -> Int { if x < 0 { 0 - x } else { x } }
      #|}
      #|Math::abs(-5)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("module block compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "simple while loop compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut sum = 0
      #|  let mut i = 0
      #|  while i < 10 {
      #|    sum += i
      #|    i += 1
      #|  }
      #|  sum
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("simple while compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "multiple assignment operators compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut x = 100
      #|  x += 10
      #|  x -= 5
      #|  x *= 2
      #|  x /= 3
      #|  x %= 7
      #|  x
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("assignment ops compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "labeled arguments compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let f = (x~: Int, y~: Int) -> Int { x + y }
      #|f(x=10, y=20)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("labeled args compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "is expression binding compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(42)
      #|let result = if x is Some(v) { v } else { 0 }
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("is expression binding compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "record destructuring let compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let r = record { x: 1, y: 2 }
      #|let record { x, y } = r
      #|x + y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("record destructure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "chained comparison compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 5
      #|let a = x > 0 && x < 10
      #|let b = x == 5 || x == 6
      #|let c = x >= 1 && x <= 100
      #|(a, b, c)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("chained comparison compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested match compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Tree { Leaf(Int); Node(Tree, Tree) }
      #|let rec sum_tree: (Tree) -> Int = (t) -> {
      #|  match t {
      #|    Leaf(n) => n,
      #|    Node(l, r) => sum_tree(l) + sum_tree(r)
      #|  }
      #|}
      #|sum_tree(Node(Leaf(1), Node(Leaf(2), Leaf(3))))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "multi-arm match with wildcard compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Color { Red; Green; Blue; Custom(Int) }
      #|let name = (c: Color) -> String {
      #|  match c {
      #|    Red => "red",
      #|    Green => "green",
      #|    Blue => "blue",
      #|    _ => "custom"
      #|  }
      #|}
      #|name(Custom(42))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("multi-arm match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "array index and length compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [10, 20, 30, 40, 50]
      #|let n = Array::length(xs)
      #|let first = xs[0]
      #|let last = xs[n - 1]
      #|first + last
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("array index compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "string methods compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|let n = String::length(s)
      #|let sub = String::substring(s, 0, 5)
      #|let has = String::contains(s, "world")
      #|(n, sub, has)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("string methods compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "mutual recursion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let rec is_even: (Int) -> Bool = (n) -> {
      #|  if n == 0 { true } else { is_odd(n - 1) }
      #|}
      #|let rec is_odd: (Int) -> Bool = (n) -> {
      #|  if n == 0 { false } else { is_even(n - 1) }
      #|}
      #|is_even(10)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("mutual recursion compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Int::to_string compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let n = 42
      #|let s = Int::to_string(n)
      #|s
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Int::to_string compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "empty typed array compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let empty: Array[Int] = []
      #|let single = [42]
      #|let n = Array::length(empty) + Array::length(single)
      #|n
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("empty typed array compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "block expression compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let result = {
      #|  let a = 10
      #|  let b = 20
      #|  a + b
      #|}
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("block expr compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "if without else compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut x = 0
      #|  if true { x = 42 }
      #|  x
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("if without else compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "multiple string interpolation parts compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let name = "world"
      #|let n = 42
      #|"hello \(name), number \(n)!"
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("multi interp compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "hex literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 0xFF
      #|let b = 0x1A
      #|a + b
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("hex literal compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "match on int literal compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let day = (n: Int) -> String {
      #|  match n {
      #|    1 => "mon",
      #|    2 => "tue",
      #|    3 => "wed",
      #|    _ => "other"
      #|  }
      #|}
      #|day(2)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("int literal match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested option match compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Option[Int]] = Some(Some(42))
      #|match x {
      #|  Some(Some(n)) => n,
      #|  Some(None) => -1,
      #|  None => -2
      #|}
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested option match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "tuple match pair compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(5)
      #|let y: Option[Int] = None
      #|match (x, y) {
      #|  (Some(a), Some(b)) => a + b,
      #|  (Some(a), None) => a,
      #|  (None, Some(b)) => b,
      #|  _ => 0
      #|}
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("tuple match pair compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "for-in inline collect compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3]
      #|for x in xs { x * 2 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in collect compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::contains compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::contains(s, "world")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::contains compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::substring compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::substring(s, 0, 5)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::substring compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::find with Ord lambda compiles" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3, 4, 5]
      #|Array::find(xs, x -> x > 3)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::find compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::reverse compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3]
      #|Array::reverse(xs)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::reverse compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::concat compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = [1, 2]
      #|let b = [3, 4]
      #|Array::concat(a, b)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::concat compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::all with Ord lambda compiles" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [2, 4, 6]
      #|Array::all(xs, x -> x > 0)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::all compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::split compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "a,b,c"
      #|String::split(s, ",")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::split compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::trim compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "  hello  "
      #|String::trim(s)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::trim compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Map::has compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "a": 1, "b": 2 }
      #|Map::has(m, "a")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map::has compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Map::keys compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "x": 1, "y": 2 }
      #|Map::keys(m)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map::keys compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "match with string literal pattern compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let greet = (name: String) -> String {
      #|  match name {
      #|    "world" => "hello world!",
      #|    "vibe" => "hello vibe!",
      #|    _ => "hello " + name
      #|  }
      #|}
      #|greet("vibe")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("string literal match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "enum with multiple payload types compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Value {
      #|  IntVal(Int);
      #|  StrVal(String);
      #|  BoolVal(Bool);
      #|  NoneVal
      #|}
      #|let to_string = (v: Value) -> String {
      #|  match v {
      #|    IntVal(_) => "int",
      #|    StrVal(s) => s,
      #|    BoolVal(b) => if b { "true" } else { "false" },
      #|    NoneVal => "none"
      #|  }
      #|}
      #|to_string(StrVal("hello"))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("multi-payload enum compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "deeply nested closure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let outer = 10
      #|let f = () -> Int {
      #|  let inner = 20
      #|  let g = () -> Int {
      #|    outer + inner
      #|  }
      #|  g()
      #|}
      #|f()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("deeply nested closure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "recursive fibonacci compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let rec fib: (Int) -> Int = (n) -> {
      #|  if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
      #|}
      #|fib(10)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("fibonacci compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "complex pattern with guard compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let classify = (x: Option[Int]) -> String {
      #|  match x {
      #|    Some(n) if n > 0 => "positive",
      #|    Some(n) if n < 0 => "negative",
      #|    Some(_) => "zero",
      #|    None => "nothing"
      #|  }
      #|}
      #|classify(Some(-5))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("complex guard compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "trait impl and usage compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Color { Red; Green; Blue } derive(Eq)
      #|let is_primary = (c: Color) -> Bool {
      #|  c == Red || c == Green || c == Blue
      #|}
      #|is_primary(Red)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("trait impl compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::index_of compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::index_of(s, "world")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::index_of compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::replace compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::replace(s, "world", "vibe")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::replace compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::starts_with compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::starts_with(s, "hello")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::starts_with compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::ends_with compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "hello world"
      #|String::ends_with(s, "world")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::ends_with compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::join compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let parts = ["a", "b", "c"]
      #|String::join(parts, ",")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String::join compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Array::slice compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3, 4, 5]
      #|Array::slice(xs, 1, 3)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Array::slice compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Map::set compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "a": 1 }
      #|let m2 = Map::set(m, "b", 2)
      #|m2["a"] + m2["b"]
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map::set compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Map::delete compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "a": 1, "b": 2 }
      #|let m2 = Map::delete(m, "a")
      #|Map::size(m2)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map::delete compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Map::values compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let m = map { "a": 10, "b": 20 }
      #|Map::values(m)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map::values compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "loop with break value compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut result = 0
      #|  loop (i = 0, sum = 0) {
      #|    if i >= 10 { result = sum; break }
      #|    continue(i + 1, sum + i)
      #|  }
      #|  result
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("loop break value compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "pipe chain with multiple steps compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let s = "  hello  "
      #|s |> String::trim |> String::length
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("pipe chain compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double arithmetic compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 1.5
      #|let b = 2.5
      #|a + b
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("double arithmetic compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double comparison compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 1.5
      #|let b = 2.5
      #|a < b
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("double comparison compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Int::to_double conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let n = 42
      #|Int::to_double(n)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Int::to_double compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double::to_int conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let d = 42.9
      #|Double::to_int(d)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Double::to_int compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Float arithmetic compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 1.5f
      #|let b = 2.5f
      #|let c = a + b
      #|let d = b - a
      #|let e = a * b
      #|let f = b / a
      #|c
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("float arithmetic compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Float comparison compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 1.5f
      #|let b = 2.5f
      #|let lt = a < b
      #|let gt = b > a
      #|let le = a <= a
      #|let ge = b >= a
      #|let eq = a == a
      #|let ne = a != b
      #|lt
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("float comparison compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Float negation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 5.0f
      #|let y = -x
      #|y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("float negation compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double negation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 5.0
      #|let y = -x
      #|y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("double negation compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double division compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a = 10.0
      #|let b = 4.0
      #|a / b
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("double division compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Int::to_float conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let n = 42
      #|Int::to_float(n)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Int::to_float compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Float::to_int conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let f = 42.9f
      #|Float::to_int(f)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Float::to_int compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Float::to_double conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let f = 1.5f
      #|Float::to_double(f)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Float::to_double compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Double::to_float conversion compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let d = 1.5
      #|Double::to_float(d)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Double::to_float compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "String::from_char_code compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|String::from_char_code(65)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("from_char_code compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "effect polymorphism compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
      #|let inc = (n: Int) -> Int { n + 1 }
      #|apply(inc, 41)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("effect poly compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "Option Eq comparison compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let a: Option[Int] = Some(42)
      #|let b: Option[Int] = Some(42)
      #|a == b
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 0)
}

///|
test "array of tuples compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let pairs = [(1, "one"), (2, "two"), (3, "three")]
      #|pairs[1].0
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("array of tuples compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "array index assign compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let xs = [1, 2, 3]
      #|  xs[0] = 10
      #|  xs[0]
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("array index assign compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "let pattern tuple destructure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let (a, b, c) = (1, 2, 3)
      #|a + b + c
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let pat tuple compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "let pattern record destructure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let r = record { x: 10, y: 20 }
      #|let record { x, y } = r
      #|x + y
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let pat record compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "let pattern constructor compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let Some(v) = Some(42)
      #|v
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("let pat ctor compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested tuple destructure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let ((a, b), (c, d)) = ((1, 2), (3, 4))
      #|a + b + c + d
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested tuple destruct compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "loop with multiple parameters compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut result = 0
      #|  loop (i = 0, a = 1, b = 0) {
      #|    if i >= 10 { result = a; break }
      #|    continue(i + 1, a + b, a)
      #|  }
      #|  result
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("loop multi param compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "struct with match destructure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|struct Point { x: Int; y: Int }
      #|let p = Point::{ x: 3, y: 4 }
      #|let d = match p {
      #|  Point::{ x, y } => x * x + y * y,
      #|  _ => 0
      #|}
      #|d
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("struct match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "struct match without wildcard compiles to wasm (#221)" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|struct Point { x: Int; y: Int }
      #|let p = Point::{ x: 3, y: 4 }
      #|let d = match p {
      #|  Point::{ x, y } => x * x + y * y
      #|}
      #|d
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("struct match without wildcard failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "tuple Option match exhaustive (#216)" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(5)
      #|let y: Option[Int] = None
      #|let sum = match (x, y) {
      #|  (Some(a), Some(b)) => a + b,
      #|  (Some(a), None) => a,
      #|  (None, Some(b)) => b,
      #|  (None, None) => 0
      #|}
      #|sum
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("tuple Option match failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "array spread compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [1, 2, 3]
      #|let ys = [0, ..xs, 4]
      #|ys
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("array spread compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "nested string interpolation compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x = 1
      #|let y = 2
      #|let z = 3
      #|"x=\(x), y=\(y), z=\(z), sum=\(x + y + z)"
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested interp compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "multiple error handlers compile to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let risky = (x: Int) -> Int with { Error } {
      #|  if x == 0 { throw("zero") }
      #|  if x < 0 { throw("negative") }
      #|  x * 2
      #|}
      #|let a = handle { risky(5) } with Error { Throw(_) => -1 }
      #|let b = handle { risky(0) } with Error { Throw(_) => -2 }
      #|let c = handle { risky(-1) } with Error { Throw(_) => -3 }
      #|a + b + c
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("multiple error handlers compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "closure returning closure compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let make_adder = (n: Int) -> (Int) -> Int {
      #|  (x: Int) -> Int { x + n }
      #|}
      #|let add5 = make_adder(5)
      #|add5(10)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("closure returning closure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "mutable in nested scope compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let run = () -> Int {
      #|  let mut x = 0
      #|  let inc = () -> Unit { x += 1 }
      #|  inc()
      #|  inc()
      #|  inc()
      #|  x
      #|}
      #|run()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("mutable nested scope compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "for-in with index and body compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = ["a", "b", "c"]
      #|for i, x in xs { (i, x) }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in index body compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "function type in tuple type annotation parses" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply: ((Int) -> Int, Int) -> Int = (f, x) -> f(x)
      #|let double: (Int) -> Int = (x) -> x * 2
      #|apply(double, 5)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("function type param parse failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P1: derive(Eq) + match compiles to wasm
test "derive(Eq) enum compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Color { Red; Green; Blue } derive(Eq)
      #|let c: Color = Color::Red
      #|if c == Color::Red { 1 } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("derive(Eq) compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P1: nested enum pattern matching compiles to wasm
test "nested enum pattern matching compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|match Some(Some(42)) { Some(Some(x)) => x, _ => 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("nested enum match compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P1: loop + break(value) with multi-param compiles to wasm
test "loop with break value multi-param compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let result = loop (i = 0, sum = 0) {
      #|  if i >= 10 { break(sum) }
      #|  continue(i + 1, sum + i)
      #|}
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("loop break(value) compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P2: generic function compiles to wasm
test "generic function compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let identity = [T](x: T) -> T { x }
      #|identity(42)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("generic function compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P2: is-expression compiles to wasm
test "is-expression compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let x: Option[Int] = Some(42)
      #|if x is Some(v) { v } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("is-expression compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P2: array spread with concat compiles to wasm
test "array spread with concat compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let xs = [2, 3]
      #|let ys = [1, ..xs, 4]
      #|Array::length(ys)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("array spread compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P2: multi-step pipe chain compiles to wasm
test "multi-step pipe chain compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let inc = (x: Int) -> Int { x + 1 }
      #|let dbl = (x: Int) -> Int { x * 2 }
      #|3 |> inc |> dbl
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("pipe chain compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// #203 P1: HOF with non-Int return type compiles to wasm
test "HOF with non-Int return type compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply = (f: (Int) -> Bool, x: Int) -> Bool { f(x) }
      #|let is_pos = (n: Int) -> Bool { n > 0 }
      #|if apply(is_pos, 5) { 1 } else { 0 }
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("HOF non-Int compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "HOF with non-Int types compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply: ((String) -> String, String) -> String = (f, x) -> f(x)
      #|let shout: (String) -> String = (s) -> String::concat(s, "!")
      #|String::length(apply(shout, "hello"))
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("HOF non-Int types compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "HOF with Option return type compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let map_opt: ((Int) -> Int, Option[Int]) -> Option[Int] = (f, opt) -> {
      #|  match opt {
      #|    Some(v) => Some(f(v)),
      #|    None => None
      #|  }
      #|}
      #|let double: (Int) -> Int = (x) -> x * 2
      #|match map_opt(double, Some(21)) {
      #|  Some(v) => v,
      #|  None => 0
      #|}
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("HOF Option compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "error effect with throw+handle compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let risky = () -> Int with { Error } {
      #|  throw("fail")
      #|  0
      #|}
      #|let result = handle { risky() } with Error { Throw(_) => -1 }
      #|result
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("effect compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
test "HOF with pure function compiles to wasm" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let apply = (f: (Int) -> Int, x: Int) -> Int { f(x) }
      #|let safe = (x: Int) -> Int { x + 1 }
      #|apply(safe, 41)
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("effect polymorphism pure compile failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 2: for-in over Array now routes through the unified
// `iter_require` / `iter_length` / `iter_get` desugar. This regression test
// pins the behavior end-to-end: a for-in over Array compiles with the
// Iterable trait constraint enforced, and ArrayView (Array slice) iterates
// correctly through the same path because `iter_length` / `iter_get` codegen
// mirrors `Array::length` / `Array::get`.
test "for-in over Array slice compiles to wasm (ADR-0044 Phase 2)" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let sum_slice = (xs: Array[Int]) -> Int {
      #|  let s = Array::slice(xs, 1, 4)
      #|  let mut total = 0
      #|  for v in s { total = total + v }
      #|  total
      #|}
      #|sum_slice([10, 20, 30, 40, 50])
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in over slice failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 2: for-in over a user-defined Iterable type compiles
// when `<Type>::iter_length` and `<Type>::iter_get` are provided. The
// monoify pass specializes the desugared iter calls to the impl helpers.
test "for-in over user Iterable compiles via iter_length/iter_get" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|enum Trio[T] { Trio(T, T, T) }
      #|impl [T] Iterable for Trio[T]
      #|let trio_of3 = [T](a: T, b: T, c: T) -> Trio[T] { Trio(a, b, c) }
      #|let Trio::iter_length = [T](_xs: Trio[T]) -> Int { 3 }
      #|let Trio::iter_get = [T](xs: Trio[T], index: Int) -> T {
      #|  match xs {
      #|    Trio(a, b, c) => if index == 0 { a } else if index == 1 { b } else { c }
      #|  }
      #|}
      #|let sum_trio = () -> Int {
      #|  let mut total = 0
      #|  for v in trio_of3(1, 2, 3) { total = total + v }
      #|  total
      #|}
      #|sum_trio()
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("for-in over Trio failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 2: for-in over a non-Iterable value is rejected by the
// type checker because the desugared `iter_require[C: Iterable]` cannot
// satisfy the trait bound.
test "for-in over non-Iterable rejected (ADR-0044 Phase 2)" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|for v in 42 { v }
    ),
  )
  let result : Result[Bytes, WasmCompileError] = try? compile_module_wasm_no_dce(
    db, "main",
  )
  match result {
    Err(_) => ()
    Ok(_) => fail("expected for-in over Int to fail typecheck")
  }
}

///|
// ADR-0044 Phase 3: String now implements Iterable. The prelude provides
// `String::iter_length` (= String::length) and `String::iter_get`
// (= String::char_code_at), so generic Iterable combinators
// (`Iterator::fold`/`map`/etc.) work over String values, with each element
// visible as the Int char code (matching the existing for-in over String
// shape).
test "Iterable for String — iter_length / iter_get compile" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let str_total = (s: String) -> Int {
      #|  let len = String::iter_length(s)
      #|  let mut acc = 0
      #|  let mut i = 0
      #|  while i < len {
      #|    acc = acc + String::iter_get(s, i)
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
      #|str_total("abc")
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("String iter helpers failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 3: a generic Iterable combinator typechecks and specializes
// when invoked on a String. The body uses `xs|>iter_length` /
// `xs|>iter_get(i)`, which the monoify pass rewrites to
// `String::iter_length` / `String::iter_get` once the receiver type is known
// to be String.
test "Iterable for String — generic Iterator::fold over String compiles" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
      #|let total_str = Iterator::fold("abc", 0, (acc: Int, c: Int) -> Int { acc + c })
      #|total_str
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Iterator::fold over String failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 3: Map[K, V] now implements Iterable, yielding K (the key)
// per iteration — matches Python/JS dict-iteration shape. The prelude
// `Map::iter_length` returns `Map::size(m)`, and `Map::iter_get` returns the
// i-th key. Compiled backends lower both helpers directly to the map storage
// layout, so generic Map iteration no longer allocates `Map::keys` per item.
test "Iterable for Map — iter_length / iter_get compile" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let key_sum = (m: Map[String, Int]) -> Int {
      #|  let len = Map::iter_length(m)
      #|  let mut acc = 0
      #|  let mut i = 0
      #|  while i < len {
      #|    let k = Map::iter_get(m, i)
      #|    acc = acc + Map::get(m, k)
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
      #|key_sum(map { "a": 1, "b": 2, "c": 3 })
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Map iter helpers failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

///|
// ADR-0044 Phase 3: a generic Iterable combinator typechecks and specializes
// when invoked on a Map. Monoify rewrites `xs|>iter_length` /
// `xs|>iter_get(i)` to `Map::iter_length` / `Map::iter_get`, which yield
// keys for the consumer.
test "Iterable for Map — generic Iterator::fold over Map compiles" {
  let db = @runtime.VibeDb::new()
  db.set_source(
    "main",
    (
      #|let Iterator::fold = [C: Iterable, T, B](xs: C, init: B, f: (acc: B, x: T) -> B) -> B {
      #|  let len = xs|>iter_length
      #|  let mut i = 0
      #|  let mut acc = init
      #|  while i < len {
      #|    acc = f(acc, xs|>iter_get(i))
      #|    i = i + 1
      #|  }
      #|  acc
      #|}
      #|let m = map { "a": 1, "b": 2 }
      #|let total = Iterator::fold(m, 0, (acc: Int, k: String) -> Int {
      #|  acc + Map::get(m, k)
      #|})
      #|total
    ),
  )
  let wasm_bytes = compile_module_wasm_no_dce(db, "main") catch {
    e => fail("Iterator::fold over Map failed: " + e.user_message())
  }
  assert_true(wasm_bytes.length() > 8)
}

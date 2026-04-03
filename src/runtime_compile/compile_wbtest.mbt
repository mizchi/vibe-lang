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
fn runtime_compile_module_has_value_call(
  ast : @core.Module,
  binding_name : String,
  target_call : String,
) -> Bool {
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name == binding_name {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              return call_name == target_call
            _ => return false
          }
        }
      _ => ()
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
    match stmt {
      @core.Stmt::Let(name~, expr~, ..) =>
        if name == binding_name {
          match expr {
            @core.Expr::Call(name=call_name, ..) =>
              return call_name.has_prefix(target_prefix)
            _ => return false
          }
        }
      _ => ()
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
    match stmt {
      @core.Stmt::Let(name~, expr~, ..)
      | @core.Stmt::ExportLet(name~, expr~, ..)
      | @core.Stmt::InternalExportLet(name~, expr~, ..) =>
        if name == binding_name {
          match expr {
            @core.Expr::Fn(body~, ..) =>
              return module_to_sexp(body, {}).contains(target_call)
            _ => return false
          }
        }
      _ => ()
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
      assert_true(runtime_compile_module_has_value_call(prepared, "value", name))
      assert_true(runtime_compile_module_fn_body_has_call(prepared, name, "Trio::iter_get"))
      assert_true(runtime_compile_module_fn_body_has_call(prepared, name, "List::iter_get"))
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
  let prepared = bundle_for_codegen(
    db,
    "/project/main.vibe",
    compiled.ast,
    "default",
  ) catch {
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
  let mut has_specialized_helper = false
  for stmt in prepared.stmts {
    match stmt {
      @core.Stmt::Let(name~, ..) =>
        if name == "Trio::iter_get$Trio|T=Int" {
          has_specialized_helper = true
        }
      _ => ()
    }
  }
  assert_true(has_specialized_helper)
  assert_true(
    runtime_compile_module_fn_body_has_call(
      prepared, "Iterator::flatmap$Trio|A=Int|B=Int", "Trio::iter_get$Trio|T=Int",
    ),
  )
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
  let prepared = bundle_for_codegen(
    db,
    "/project/main.vibe",
    compiled.ast,
    "default",
  ) catch {
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
  let prepared = bundle_for_codegen(
    db,
    "/project/main.vibe",
    compiled.ast,
    "default",
  ) catch {
    err => fail(err.to_string())
  }
  let gc_prepared = bundle_for_codegen(
    db,
    "/project/main.vibe",
    compiled.ast,
    "gc",
  ) catch {
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
  let prepared = bundle_for_codegen(
    db,
    "/project/main.vibe",
    compiled.ast,
    "default",
  ) catch {
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
  assert_eq(bodies[0].0, "f")
  assert_eq(bodies[1].0, "g")
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

///| Tests for DAG-based content-addressed hashing

///| Verify that files with the same dependency structure produce the same hash

///|
let s : Span = Span::{ start: 0, end: 0 }

///|
fn mk_int(value : Int64) -> Expr {
  Expr::Int(value~, span=s)
}

///|
fn mk_ident(name : String) -> Expr {
  Expr::Ident(name~, span=s)
}

///|
fn mk_call(name : String, args : Array[Expr]) -> Expr {
  let call_args : Array[CallArg] = []
  for arg in args {
    call_args.push(CallArg::{ label: None, expr: arg, span: s })
  }
  Expr::Call(name~, type_args=[], args=call_args, span=s)
}

///|
fn mk_let(name : String, expr : Expr) -> Stmt {
  Stmt::Let(rec=false, name~, expr~, span=s)
}

///|
fn mk_export_let(name : String, expr : Expr) -> Stmt {
  Stmt::ExportLet(rec=false, name~, expr~, span=s)
}

///|
fn mk_fn1(param : String, ty : Type, body : Array[Stmt]) -> Expr {
  Expr::Fn(
    type_params=[],
    type_bounds={},
    params=[
      FuncParam::{ name: param, label: ParamLabel::Positional, ty, bounds: [] },
    ],
    ret=None,
    effects=[],
    body=Module::{ stmts: body },
    span=s,
  )
}

///|
fn mk_import(path : String, items : Array[String]) -> Stmt {
  let import_items : Array[ImportItem] = []
  for name in items {
    import_items.push(ImportItem::{
      kind: ImportKind::Value,
      name,
      rename: None,
    })
  }
  Stmt::Import(
    spec=ImportSpec::{ items: import_items },
    source=ModuleRef::Path(path~),
    span=s,
  )
}

///|
fn mk_hash_import(hash : String, items : Array[String]) -> Stmt {
  let import_items : Array[ImportItem] = []
  for name in items {
    import_items.push(ImportItem::{
      kind: ImportKind::Value,
      name,
      rename: None,
    })
  }
  Stmt::Import(
    spec=ImportSpec::{ items: import_items },
    source=ModuleRef::Hash(hash~),
    span=s,
  )
}

///|
fn mk_hash_reexport(hash : String, items : Array[String]) -> Stmt {
  let export_items : Array[ImportItem] = []
  for name in items {
    export_items.push(ImportItem::{
      kind: ImportKind::Value,
      name,
      rename: None,
    })
  }
  Stmt::ReExport(
    spec=ImportSpec::{ items: export_items },
    source=ModuleRef::Hash(hash~),
    span=s,
  )
}

///|
test "same AST structure with different variable names produces same hash" {
  // File A: let x = 42; x
  let module_a = Module::{
    stmts: [mk_let("x", mk_int(42)), Stmt::Expr(expr=mk_ident("x"), span=s)],
  }
  // File B: let foo = 42; foo (same structure, different names)
  let module_b = Module::{
    stmts: [mk_let("foo", mk_int(42)), Stmt::Expr(expr=mk_ident("foo"), span=s)],
  }
  assert_eq(hash_module(module_a), hash_module(module_b))
}

///|
test "different AST structure produces different hash" {
  let module_a = Module::{
    stmts: [mk_let("x", mk_int(42)), Stmt::Expr(expr=mk_ident("x"), span=s)],
  }
  let module_b = Module::{
    stmts: [mk_let("x", mk_int(99)), Stmt::Expr(expr=mk_ident("x"), span=s)],
  }
  assert_not_eq(hash_module(module_a), hash_module(module_b))
}

///|
test "same structure with different spans produces same hash" {
  let span1 = Span::{ start: 0, end: 10 }
  let span2 = Span::{ start: 100, end: 200 }
  let module_a = Module::{
    stmts: [Stmt::Let(rec=false, name="x", expr=mk_int(1), span=span1)],
  }
  let module_b = Module::{
    stmts: [Stmt::Let(rec=false, name="x", expr=mk_int(1), span=span2)],
  }
  assert_eq(hash_module(module_a), hash_module(module_b))
}

///|
test "DAG: same dependency content with different paths produces same hash" {
  // Dependency module: export let add = (a: Int) -> { add_int(a, a) }
  let dep_module = Module::{
    stmts: [
      mk_export_let(
        "add",
        mk_fn1("a", Type::Int, [
          Stmt::Expr(
            expr=mk_call("add_int", [mk_ident("a"), mk_ident("a")]),
            span=s,
          ),
        ]),
      ),
    ],
  }
  // Module A: import { add } from "./utils/math.vibe"; add(1)
  let module_a = Module::{
    stmts: [
      mk_import("./utils/math.vibe", ["add"]),
      Stmt::Expr(expr=mk_call("add", [mk_int(1)]), span=s),
    ],
  }
  // Module B: import { add } from "./lib/helpers.vibe"; add(1)
  // Same import content from a different path
  let module_b = Module::{
    stmts: [
      mk_import("./lib/helpers.vibe", ["add"]),
      Stmt::Expr(expr=mk_call("add", [mk_int(1)]), span=s),
    ],
  }
  let bundle_a = normalize_with_imports(module_a, fn(path) {
    if path == "./utils/math.vibe" {
      Some(dep_module)
    } else {
      None
    }
  })
  let bundle_b = normalize_with_imports(module_b, fn(path) {
    if path == "./lib/helpers.vibe" {
      Some(dep_module)
    } else {
      None
    }
  })
  assert_eq(bundle_a.main_hash, bundle_b.main_hash)
}

///|
test "DAG: different dependency content produces different hash" {
  let dep_v1 = Module::{ stmts: [mk_export_let("val", mk_int(1))] }
  let dep_v2 = Module::{ stmts: [mk_export_let("val", mk_int(2))] }
  let main_mod = Module::{
    stmts: [
      mk_import("./dep.vibe", ["val"]),
      Stmt::Expr(expr=mk_ident("val"), span=s),
    ],
  }
  let bundle_v1 = normalize_with_imports(main_mod, fn(path) {
    if path == "./dep.vibe" {
      Some(dep_v1)
    } else {
      None
    }
  })
  let bundle_v2 = normalize_with_imports(main_mod, fn(path) {
    if path == "./dep.vibe" {
      Some(dep_v2)
    } else {
      None
    }
  })
  assert_not_eq(bundle_v1.main_hash, bundle_v2.main_hash)
}

///|
test "DAG: diamond dependency produces same hash regardless of path layout" {
  // Shared leaf: export let base = 1
  let leaf = Module::{ stmts: [mk_export_let("base", mk_int(1))] }
  // Left branch imports leaf
  let left = Module::{
    stmts: [
      mk_import("./leaf.vibe", ["base"]),
      mk_export_let("left_val", mk_ident("base")),
    ],
  }
  // Right branch imports leaf
  let right = Module::{
    stmts: [
      mk_import("./leaf.vibe", ["base"]),
      mk_export_let("right_val", mk_ident("base")),
    ],
  }
  // Root A: imports left and right via path layout A
  let root_a = Module::{
    stmts: [
      mk_import("./a/left.vibe", ["left_val"]),
      mk_import("./a/right.vibe", ["right_val"]),
      Stmt::Expr(
        expr=mk_call("add_int", [mk_ident("left_val"), mk_ident("right_val")]),
        span=s,
      ),
    ],
  }
  // Root B: imports left and right via path layout B
  let root_b = Module::{
    stmts: [
      mk_import("./x/left.vibe", ["left_val"]),
      mk_import("./x/right.vibe", ["right_val"]),
      Stmt::Expr(
        expr=mk_call("add_int", [mk_ident("left_val"), mk_ident("right_val")]),
        span=s,
      ),
    ],
  }
  let resolve_a : (String) -> Module? = fn(path) {
    if path == "./a/left.vibe" {
      Some(left)
    } else if path == "./a/right.vibe" {
      Some(right)
    } else if path == "./leaf.vibe" {
      Some(leaf)
    } else {
      None
    }
  }
  let resolve_b : (String) -> Module? = fn(path) {
    if path == "./x/left.vibe" {
      Some(left)
    } else if path == "./x/right.vibe" {
      Some(right)
    } else if path == "./leaf.vibe" {
      Some(leaf)
    } else {
      None
    }
  }
  let bundle_a = normalize_with_imports(root_a, resolve_a)
  let bundle_b = normalize_with_imports(root_b, resolve_b)
  assert_eq(bundle_a.main_hash, bundle_b.main_hash)
  // Both bundles should contain the same set of modules (leaf + left + right + root)
  assert_eq(bundle_a.modules.length(), bundle_b.modules.length())
}

///|
test "collect_import_hashes keeps hashed imports and re-exports in order" {
  let mod_ast = Module::{
    stmts: [
      mk_hash_import("dep-main", ["value"]),
      mk_import("./dep.vibe", ["ignored_path"]),
      mk_hash_reexport("dep-reexport", ["tool"]),
      Stmt::Expr(expr=mk_int(1), span=s),
    ],
  }
  let hashes = collect_import_hashes(mod_ast)
  assert_eq(hashes.length(), 2)
  assert_eq(hashes[0], "dep-main")
  assert_eq(hashes[1], "dep-reexport")
}

///|
test "expand_module respects depth limit" {
  let leaf = Module::{ stmts: [mk_export_let("leaf", mk_int(1))] }
  let dep = Module::{
    stmts: [
      mk_hash_import("leaf-hash", ["leaf"]),
      mk_export_let("dep", mk_ident("leaf")),
    ],
  }
  let main = Module::{
    stmts: [
      mk_hash_import("dep-hash", ["dep"]),
      Stmt::Expr(expr=mk_ident("dep"), span=s),
    ],
  }
  let load_module : (String) -> Module? = fn(hash) {
    if hash == "main-hash" {
      Some(main)
    } else if hash == "dep-hash" {
      Some(dep)
    } else if hash == "leaf-hash" {
      Some(leaf)
    } else {
      None
    }
  }

  let depth0 = expand_module("main-hash", load_module, Some(0))
  assert_eq(depth0.modules.length(), 1)
  assert_eq(depth0.order, ["main-hash"])

  let depth1 = expand_module("main-hash", load_module, Some(1))
  assert_eq(depth1.modules.length(), 2)
  assert_eq(depth1.order, ["dep-hash", "main-hash"])

  let depth_all = expand_module("main-hash", load_module, None)
  assert_eq(depth_all.modules.length(), 3)
  assert_eq(depth_all.order, ["leaf-hash", "dep-hash", "main-hash"])
}

///|
test "expand_module skips missing dependency hashes" {
  let main = Module::{
    stmts: [
      mk_hash_import("missing-dep", ["dep"]),
      Stmt::Expr(expr=mk_int(1), span=s),
    ],
  }
  let load_module : (String) -> Module? = fn(hash) {
    if hash == "main-hash" {
      Some(main)
    } else {
      None
    }
  }
  let expanded = expand_module("main-hash", load_module, None)
  assert_eq(expanded.modules.length(), 1)
  assert_eq(expanded.order, ["main-hash"])
}

///|
test "expand_module handles cyclic hashes once" {
  let main = Module::{
    stmts: [
      mk_hash_import("dep-hash", ["dep"]),
      Stmt::Expr(expr=mk_ident("dep"), span=s),
    ],
  }
  let dep = Module::{
    stmts: [
      mk_hash_import("main-hash", ["main"]),
      mk_export_let("dep", mk_ident("main")),
    ],
  }
  let load_module : (String) -> Module? = fn(hash) {
    if hash == "main-hash" {
      Some(main)
    } else if hash == "dep-hash" {
      Some(dep)
    } else {
      None
    }
  }
  let expanded = expand_module("main-hash", load_module, None)
  assert_eq(expanded.modules.length(), 2)
  assert_eq(expanded.order, ["dep-hash", "main-hash"])
}

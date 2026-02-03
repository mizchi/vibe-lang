///| Incremental xsh database using ripple

pub struct Diagnostic {
  stage : String
  message : String
} derive(Show, Eq)

pub struct ImportSpec {
  path : String
  alias_name : String
  hash : String?
  module_ref : String?
} derive(Show, Eq)

pub struct XshDb {
  db : @ripple.Database
  rt : @ripple.Runtime
  sources : @ripple.Input[String, String]
  cst_query : @ripple.Query[String, @cst.SyntaxNode]
  ast_query : @ripple.Query[String, Module]
  type_query : @ripple.Query[String, TypeEnv]
  import_query : @ripple.Query[String, Array[ImportSpec]]
  diags : @ripple.Accumulator[Diagnostic]
}

///|
pub fn XshDb::new() -> XshDb {
  let db = @ripple.Database::new()
  let rt = db.runtime()
  let sources : @ripple.Input[String, String] = db.input()
  sources.register(rt)
  let diags : @ripple.Accumulator[Diagnostic] = db.accumulator()

  let cst_query : @ripple.Query[String, @cst.SyntaxNode] = db.query(
    fn(rt, path) {
      match sources.get(rt, path) {
        Some(content) => parse_cst(content)
        None => parse_cst("")
      }
    },
  )
  cst_query.register(rt)

  let ast_query : @ripple.Query[String, Module] = db.query(
    fn(rt, path) {
      match sources.get(rt, path) {
        Some(content) =>
          try {
            parse_ast(content)
          } catch {
            e => {
              diags.push(rt, Diagnostic::{ stage: "parse", message: e.to_string() })
              { stmts: [] }
            }
          }
        None => { stmts: [] }
      }
    },
  )
  ast_query.register(rt)

  let type_query : @ripple.Query[String, TypeEnv] = db.query(
    fn(rt, path) {
      let ast = ast_query.fetch(rt, path)
      try {
        type_check(ast)
      } catch {
        e => {
          diags.push(rt, Diagnostic::{ stage: "type", message: e.to_string() })
          TypeEnv::new()
        }
      }
    },
  )
  type_query.register(rt)

  let import_query : @ripple.Query[String, Array[ImportSpec]] = db.query(
    fn(rt, path) {
      let ast = ast_query.fetch(rt, path)
      let out : Array[ImportSpec] = []
      for stmt in ast.stmts {
        match stmt {
          Stmt::Import(path~) => {
            let alias_name = import_alias_name(path)
            match sources.get(rt, path) {
              Some(content) => {
                let hash = git_blob_hash_string(content)
                out.push(ImportSpec::{
                  path,
                  alias_name,
                  hash: Some(hash),
                  module_ref: Some(module_ref_from_hash(hash)),
                })
              }
              None => {
                diags.push(rt, Diagnostic::{ stage: "import", message: "missing: " + path })
                out.push(ImportSpec::{ path, alias_name, hash: None, module_ref: None })
              }
            }
          }
          _ => ()
        }
      }
      out
    },
  )
  import_query.register(rt)

  { db, rt, sources, cst_query, ast_query, type_query, import_query, diags }
}

///|
pub fn XshDb::set_source(self : XshDb, path : String, content : String) -> Unit {
  let _ = self.sources.set(self.rt, path, content)
}

///|
pub fn XshDb::cst(self : XshDb, path : String) -> @cst.SyntaxNode {
  self.cst_query.fetch(self.rt, path)
}

///|
pub fn XshDb::ast(self : XshDb, path : String) -> Module {
  self.ast_query.fetch(self.rt, path)
}

///|
pub fn XshDb::types(self : XshDb, path : String) -> TypeEnv {
  self.type_query.fetch(self.rt, path)
}

///|
pub fn XshDb::imports(self : XshDb, path : String) -> Array[ImportSpec] {
  self.import_query.fetch(self.rt, path)
}

///|
pub fn XshDb::get_source(self : XshDb, path : String) -> String? {
  self.sources.get(self.rt, path)
}

///| Build alias map from imports (alias -> module ref)
pub fn XshDb::import_aliases(self : XshDb, path : String) -> Map[String, Ref] {
  let imports = self.import_query.fetch(self.rt, path)
  let aliases : Map[String, Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) => {
        aliases[imp.alias_name] = Ref::{ name: m, hash_prefix: None }
      }
      None => ()
    }
  }
  aliases
}

///| Collect diagnostics from parse/type stages
pub fn XshDb::diagnostics(self : XshDb, path : String) -> Array[Diagnostic] {
  let parse_diags = self.diags.get_for_query(self.ast_query, path)
  let type_diags = self.diags.get_for_query(self.type_query, path)
  let import_diags = self.diags.get_for_query(self.import_query, path)
  let out : Array[Diagnostic] = []
  for d in parse_diags {
    out.push(d)
  }
  for d in type_diags {
    out.push(d)
  }
  for d in import_diags {
    out.push(d)
  }
  out
}

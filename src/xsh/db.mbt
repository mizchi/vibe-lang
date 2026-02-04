///|
/// Incremental xsh database using ripple
pub struct ImportSpec {
  path : String
  alias_name : String
  hash : String?
  module_ref : String?
} derive(Show, Eq)

///|
pub struct XshDb {
  db : @ripple.Database
  rt : @ripple.Runtime
  sources : @ripple.Input[String, String]
  cst_query : @ripple.Query[String, @cst.SyntaxNode]
  ast_query : @ripple.Query[String, @core.Module]
  type_query : @ripple.Query[String, @checker.TypeEnv]
  import_query : @ripple.Query[String, Array[ImportSpec]]
  diags : @ripple.Accumulator[@core.Diagnostic]
}

///|
pub fn XshDb::new() -> XshDb {
  let db = @ripple.Database::new()
  let rt = db.runtime()
  let sources : @ripple.Input[String, String] = db.input()
  sources.register(rt)
  let diags : @ripple.Accumulator[@core.Diagnostic] = db.accumulator()
  let cst_query : @ripple.Query[String, @cst.SyntaxNode] = db.query(fn(
    rt,
    path,
  ) {
    match sources.get(rt, path) {
      Some(content) => @parser.parse_cst(content)
      None => @parser.parse_cst("")
    }
  })
  cst_query.register(rt)
  let ast_query : @ripple.Query[String, @core.Module] = db.query(fn(rt, path) {
    match sources.get(rt, path) {
      Some(content) =>
        @parser.parse_ast(content) catch {
          e => {
            diags.push(rt, e.diagnostic())
            { stmts: [] }
          }
        }
      None => { stmts: [] }
    }
  })
  ast_query.register(rt)
  let import_query : @ripple.Query[String, Array[ImportSpec]] = db.query(fn(
    rt,
    path,
  ) {
    let ast = ast_query.fetch(rt, path)
    let out : Array[ImportSpec] = []
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Import(path~, span~) => {
          let _ = span
          let alias_name = @core.import_alias_name(path)
          match sources.get(rt, path) {
            Some(content) => {
              let hash = @core.git_blob_hash_string(content)
              out.push(ImportSpec::{
                path,
                alias_name,
                hash: Some(hash),
                module_ref: Some(@core.module_ref_from_hash(hash)),
              })
            }
            None => {
              diags.push(rt, @core.Diagnostic::{
                stage: "import",
                message: "missing: " + path,
                span: Some(span),
                hint: None,
                note: None,
              })
              out.push(ImportSpec::{
                path,
                alias_name,
                hash: None,
                module_ref: None,
              })
            }
          }
        }
        _ => ()
      }
    }
    out
  })
  import_query.register(rt)
  let type_query : @ripple.Query[String, @checker.TypeEnv] = db.query(fn(
    rt,
    path,
  ) {
    let ast = ast_query.fetch(rt, path)
    let imports = import_query.fetch(rt, path)
    let aliases = build_alias_map_from_ast(ast, imports)
    let desugared = desugar_method_calls(ast, aliases)
    @checker.type_check_with_aliases(desugared, aliases) catch {
      e => {
        diags.push(rt, e.diagnostic())
        @checker.TypeEnv::new()
      }
    }
  })
  type_query.register(rt)
  { db, rt, sources, cst_query, ast_query, type_query, import_query, diags }
}

///|
fn build_alias_map_from_ast(
  ast : @core.Module,
  imports : Array[ImportSpec],
) -> Map[String, @core.Ref] {
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Alias(name~, target~, span~) => {
        let _ = span
        match target {
          @core.AliasTarget::Module(r) => aliases[name] = r
          @core.AliasTarget::Name(_) => ()
        }
      }
      _ => ()
    }
  }
  aliases
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
pub fn XshDb::ast(self : XshDb, path : String) -> @core.Module {
  self.ast_query.fetch(self.rt, path)
}

///|
pub fn XshDb::types(self : XshDb, path : String) -> @checker.TypeEnv {
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

///|
/// Build alias map from imports (alias -> module ref)
pub fn XshDb::import_aliases(
  self : XshDb,
  path : String,
) -> Map[String, @core.Ref] {
  let imports = self.import_query.fetch(self.rt, path)
  let aliases : Map[String, @core.Ref] = {}
  for imp in imports {
    match imp.module_ref {
      Some(m) =>
        aliases[imp.alias_name] = @core.Ref::{ name: m, hash_prefix: None }
      None => ()
    }
  }
  aliases
}

///|
/// Collect diagnostics from parse/type stages
pub fn XshDb::diagnostics(
  self : XshDb,
  path : String,
) -> Array[@core.Diagnostic] {
  let parse_diags = self.diags.get_for_query(self.ast_query, path)
  let type_diags = self.diags.get_for_query(self.type_query, path)
  let import_diags = self.diags.get_for_query(self.import_query, path)
  let out : Array[@core.Diagnostic] = []
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

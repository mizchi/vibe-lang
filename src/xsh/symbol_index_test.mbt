///|
fn parse_index_source(path : String, source : String) -> SymbolIndex {
  let ast = @parser.parse_ast(source) catch {
    e => abort("parse failed: " + e.to_string())
  }
  let env = @checker.type_check(ast) catch {
    e => abort("typecheck failed: " + e.to_string())
  }
  build_symbol_index_for_module(path, ast, env)
}

///|
fn has_symbol(
  entries : Array[SymbolEntry],
  name : String,
  kind_name : String,
) -> Bool {
  for entry in entries {
    if entry.name == name && symbol_kind_name(entry.kind) == kind_name {
      return true
    }
  }
  false
}

///|
test "symbol index collects top-level declarations" {
  let source =
    #|enum MyOption[T] { MySome(T); MyNone }
    #|type UserId = Int
    #|struct User { id: Int; name: String }
    #|trait MyTrait
    #|let id = (x: Int) -> Int { x }
    #|let answer = 42
  let index = parse_index_source("main.xsh", source)
  let entries = index.entries
  assert_true(has_symbol(entries, "MyOption", "enum"))
  assert_true(has_symbol(entries, "MySome", "constructor"))
  assert_true(has_symbol(entries, "MyNone", "constructor"))
  assert_true(has_symbol(entries, "UserId", "type"))
  assert_true(has_symbol(entries, "User", "struct"))
  assert_true(has_symbol(entries, "MyTrait", "trait"))
  assert_true(has_symbol(entries, "id", "function"))
  assert_true(has_symbol(entries, "answer", "value"))
}

///|
test "symbol index supports exact and fuzzy search" {
  let source =
    #|let id = (x: Int) -> Int { x }
    #|let idle = 1
  let index = parse_index_source("main.xsh", source)
  let exact = index.find_exact("id")
  assert_eq(exact.length(), 1)
  assert_eq(exact[0].name, "id")
  assert_true(exact[0].signature.contains("Int"))
  let fuzzy = index.search("id")
  assert_eq(fuzzy.length(), 2)
}

///|
test "symbol index lsif output includes metadata and documents" {
  let path = "/workspace/main.xsh"
  let source =
    #|let id = (x: Int) -> Int { x }
  let index = parse_index_source(path, source)
  let lines = symbol_index_to_lsif_lines(index, fn(p) {
    if p == path {
      Some(source)
    } else {
      None
    }
  })
  assert_true(lines.length() > 0)
  let mut has_metadata = false
  let mut has_project = false
  let mut has_document = false
  let mut range_count = 0
  for line in lines {
    let json = @json.parse(line) catch {
      e => fail("lsif json parse failed: " + e.to_string())
    }
    match json {
      Json::Object(obj) =>
        match obj.get("label") {
          Some(Json::String(label)) =>
            match label {
              "metaData" => has_metadata = true
              "project" => has_project = true
              "document" => has_document = true
              "range" => range_count += 1
              _ => ()
            }
          _ => ()
        }
      _ => fail("lsif line is not object")
    }
  }
  assert_true(has_metadata)
  assert_true(has_project)
  assert_true(has_document)
  assert_true(range_count > 0)
}

///|
test "detect_language_id" {
  @debug.assert_eq(detect_language_id("foo.vibe"), Some("vibe"))
  @debug.assert_eq(detect_language_id("bar.ts"), Some("typescript"))
  @debug.assert_eq(detect_language_id("baz.tsx"), Some("typescript"))
  @debug.assert_eq(detect_language_id("mod.mts"), Some("typescript"))
  @debug.assert_eq(detect_language_id("mod.cts"), Some("typescript"))
  @debug.assert_eq(detect_language_id("app.js"), Some("javascript"))
  @debug.assert_eq(detect_language_id("app.mjs"), Some("javascript"))
  @debug.assert_eq(detect_language_id("app.cjs"), Some("javascript"))
  @debug.assert_eq(detect_language_id("main.py"), Some("python"))
  @debug.assert_eq(detect_language_id("stub.pyi"), Some("python"))
  @debug.assert_eq(detect_language_id("test.rs"), None)
}

///|
test "typescript extractor: function" {
  let rows = extract_typescript_graph_ir_rows(
    "test.ts", "export function greet(name: string): string {\n  return name\n}\n",
  )
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].name, "greet")
  assert_eq(rows[0].kind, "function")
  assert_eq(rows[0].language_id, "typescript")
}

///|
test "typescript extractor: class and interface" {
  let source = "class Foo {\n  bar() {}\n}\n\ninterface Bar {\n  baz: string\n}\n"
  let rows = extract_typescript_graph_ir_rows("test.ts", source)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "Foo")
  assert_eq(rows[0].kind, "class")
  assert_eq(rows[1].name, "Bar")
  assert_eq(rows[1].kind, "interface")
}

///|
test "typescript extractor: type and enum" {
  let source = "type Point = { x: number, y: number }\nenum Color { Red, Green, Blue }\n"
  let rows = extract_typescript_graph_ir_rows("test.ts", source)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "Point")
  assert_eq(rows[0].kind, "type")
  assert_eq(rows[1].name, "Color")
  assert_eq(rows[1].kind, "enum")
}

///|
test "typescript extractor: const and let" {
  let source = "export const MAX = 100\nlet count = 0\n"
  let rows = extract_typescript_graph_ir_rows("test.ts", source)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "MAX")
  assert_eq(rows[0].kind, "const")
  assert_eq(rows[1].name, "count")
  assert_eq(rows[1].kind, "let")
}

///|
test "typescript extractor: skips imports and comments" {
  let source = "// comment\nimport { foo } from 'bar'\n\nexport function main() {\n}\n"
  let rows = extract_typescript_graph_ir_rows("test.ts", source)
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].name, "main")
}

///|
test "python extractor: def and class" {
  let source = "def greet(name):\n    return name\n\nclass Foo:\n    pass\n"
  let rows = extract_python_graph_ir_rows("test.py", source)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "greet")
  assert_eq(rows[0].kind, "function")
  assert_eq(rows[1].name, "Foo")
  assert_eq(rows[1].kind, "class")
}

///|
test "python extractor: async def" {
  let source = "async def fetch(url):\n    pass\n"
  let rows = extract_python_graph_ir_rows("test.py", source)
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].name, "fetch")
  assert_eq(rows[0].kind, "function")
}

///|
test "python extractor: variable assignment" {
  let source = "MAX_SIZE = 100\nname: str = \"hello\"\n"
  let rows = extract_python_graph_ir_rows("test.py", source)
  assert_eq(rows.length(), 2)
  assert_eq(rows[0].name, "MAX_SIZE")
  assert_eq(rows[0].kind, "variable")
  assert_eq(rows[1].name, "name")
  assert_eq(rows[1].kind, "variable")
}

///|
test "python extractor: skips indented and imports" {
  let source = "import os\nfrom sys import argv\n\ndef main():\n    x = 1\n"
  let rows = extract_python_graph_ir_rows("test.py", source)
  assert_eq(rows.length(), 1)
  assert_eq(rows[0].name, "main")
}

///|
test "extract_graph_ir_rows_by_ext dispatches correctly" {
  // TypeScript
  let ts_result = extract_graph_ir_rows_by_ext(
    "app.ts", "export function hello() {}\n",
  )
  match ts_result {
    Ok(rows) => {
      assert_eq(rows.length(), 1)
      assert_eq(rows[0].language_id, "typescript")
    }
    Err(e) => fail(e)
  }
  // Python
  let py_result = extract_graph_ir_rows_by_ext(
    "main.py", "def world():\n    pass\n",
  )
  match py_result {
    Ok(rows) => {
      assert_eq(rows.length(), 1)
      assert_eq(rows[0].language_id, "python")
    }
    Err(e) => fail(e)
  }
  // Unknown extension
  let unknown = extract_graph_ir_rows_by_ext("file.rs", "fn main() {}")
  assert_true(unknown is Err(_))
}

///|
test "extract_graph_ir_rows_with_semantic_provider can refine baseline rows" {
  let result = extract_graph_ir_rows_with_semantic_provider(
    "app.ts",
    "export function greet(name) {}\n",
    provider=Some(fn(path, source, baseline) {
      let _ = path
      let _ = source
      if baseline.length() == 0 {
        return Ok([])
      }
      let row = baseline[0]
      let patched = new_graph_ir_row(
        row.language_id,
        row.path,
        row.name,
        row.kind,
        "function greet(name: string): string",
        row.start,
        row.end,
        row.module_hash,
        ["string"],
        row.refs,
        row.calls,
        row.imports,
      )
      Ok([patched])
    }),
  )
  match result {
    Ok(rows) => {
      assert_eq(rows.length(), 1)
      assert_eq(rows[0].signature, "function greet(name: string): string")
      @debug.assert_eq(rows[0].type_terms, ["string"])
    }
    Err(e) => fail(e)
  }
}

///|
test "extract_graph_ir_rows_with_semantic_provider appends provider-only rows" {
  let result = extract_graph_ir_rows_with_semantic_provider(
    "app.ts",
    "export function greet(name) {}\n",
    provider=Some(fn(path, source, baseline) {
      let _ = source
      let out : Array[GraphIrRow] = []
      for row in baseline {
        out.push(row)
      }
      out.push(
        new_graph_ir_row(
          "typescript",
          path,
          "extra_symbol",
          "function",
          "function extra_symbol(): void",
          100,
          120,
          @core.content_address_hash_string("extra"),
          ["void"],
          [],
          [],
          [],
        ),
      )
      Ok(out)
    }),
  )
  match result {
    Ok(rows) => {
      assert_eq(rows.length(), 2)
      assert_eq(rows[1].name, "extra_symbol")
    }
    Err(e) => fail(e)
  }
}

///|
test "extract_graph_ir_rows_with_semantic_provider wraps provider error" {
  let result = extract_graph_ir_rows_with_semantic_provider(
    "app.ts",
    "export function greet(name) {}\n",
    provider=Some(fn(_, _, _) { Err("provider failed") }),
  )
  match result {
    Ok(_) => fail("expected error")
    Err(err) => assert_eq(err, "semantic provider: provider failed")
  }
}

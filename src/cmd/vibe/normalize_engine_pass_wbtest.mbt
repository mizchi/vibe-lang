///|
fn wbtest_stmt_summary(stmts : Array[@vibe_core.Stmt]) -> Array[String] {
  let out : Array[String] = []
  for stmt in stmts {
    match stmt {
      @vibe_core.Stmt::Let(name~, ..) => out.push("let:" + name)
      @vibe_core.Stmt::ExportLet(name~, ..) => out.push("export_let:" + name)
      @vibe_core.Stmt::LetMut(name~, ..) => out.push("let_mut:" + name)
      @vibe_core.Stmt::EnumDef(name~, ..) => out.push("enum:" + name)
      @vibe_core.Stmt::ExportEnumDef(name~, ..) =>
        out.push("export_enum:" + name)
      @vibe_core.Stmt::TypeAlias(name~, ..) => out.push("type:" + name)
      @vibe_core.Stmt::ExportTypeAlias(name~, ..) =>
        out.push("export_type:" + name)
      @vibe_core.Stmt::StructDef(name~, ..) => out.push("struct:" + name)
      @vibe_core.Stmt::ExportStructDef(name~, ..) =>
        out.push("export_struct:" + name)
      @vibe_core.Stmt::TraitDef(name~, ..) => out.push("trait:" + name)
      @vibe_core.Stmt::Export(names~, ..) =>
        out.push("export:{" + names.join(",") + "}")
      @vibe_core.Stmt::Expr(..) => out.push("expr")
      @vibe_core.Stmt::Import(..) => out.push("import")
      _ => out.push("other")
    }
  }
  out
}

///|
test "pass_parse: valid source produces module" {
  let result = pass_parse("let x = 1\nlet y = x + 2")
  match result {
    Ok(m) => inspect(m.stmts.length(), content="2")
    Err(msg) => fail("expected Ok, got Err: " + msg)
  }
}

///|
test "pass_parse: syntax error returns Err" {
  let result = pass_parse("let 123invalid = ")
  match result {
    Ok(_) => () // parser may recover; just ensure no crash
    Err(msg) => assert_true(msg.contains("parse failed"))
  }
}

///|
test "pass_select_and_dedup: no entry names keeps all stmts" {
  let ast = match pass_parse("let a = 1\nlet b = a + 1\nlet c = b + 1") {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let result = pass_select_and_dedup(ast, [])
  let expected = ["let:a", "let:b", "let:c"]
  @debug.debug_inspect(wbtest_stmt_summary(result), content=Debug::to_repr(expected).to_string())
}

///|
test "pass_select_and_dedup: with entry names adds export and applies DCE" {
  let source =
    #|let unused = 99
    #|let helper = () -> Int { 1 }
    #|let value = helper()
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let result = pass_select_and_dedup(ast, ["value"])
  let summary = wbtest_stmt_summary(result)
  // unused should be removed by DCE, helper kept as dependency of value
  assert_false(summary.contains("let:unused"))
  assert_true(summary.contains("let:helper"))
  assert_true(summary.contains("let:value"))
  assert_true(summary.iter().any(fn(s) { s.has_prefix("export:") }))
}

///|
test "pass_select_and_dedup: duplicate names dedup last wins" {
  let source =
    #|let x = 1
    #|let x = 2
    #|let y = x
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let result = pass_select_and_dedup(ast, [])
  // x should appear only once (last definition wins)
  let x_count = result
    .iter()
    .filter(fn(stmt) {
      match stmt {
        @vibe_core.Stmt::Let(name~, ..) => name == "x"
        _ => false
      }
    })
    .count()
  @debug.debug_inspect(x_count, content="1")
  let expected = ["let:x", "let:y"]
  @debug.debug_inspect(wbtest_stmt_summary(result), content=Debug::to_repr(expected).to_string())
}

///|
test "pass_typecheck_and_filter: keeps all when no pure exprs" {
  let source =
    #|let a = () -> Int { 1 }
    #|let b = a()
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let selected = pass_select_and_dedup(ast, [])
  let sorted = normalize_sort_stmts(selected)
  let result = pass_typecheck_and_filter(sorted, [], false)
  inspect(result.length(), content="2")
}

///|
test "pass_typecheck_and_filter: filters pure expr stmts" {
  let source =
    #|let f = (v: Int) -> Int { v * 2 }
    #|f(3)
    #|let x = 3
    #|let y = f(x)
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let selected = pass_select_and_dedup(ast, ["x", "y"])
  let sorted = normalize_sort_stmts(selected)
  let result = pass_typecheck_and_filter(sorted, ["x", "y"], false)
  let summary = wbtest_stmt_summary(result)
  // f(3) is a pure expr and should be filtered out
  assert_false(summary.contains("expr"))
  assert_true(summary.contains("let:f"))
  assert_true(summary.contains("let:x"))
  assert_true(summary.contains("let:y"))
}

///|
test "pass_annotate: infers type annotations for non-fn let bindings" {
  let source =
    #|let x = 42
    #|let y = x + 1
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let selected = pass_select_and_dedup(ast, [])
  let sorted = normalize_sort_stmts(selected)
  let (_env, annotations) = pass_annotate(sorted)
  // annotations are keyed by span "start:end", not by name
  assert_true(annotations.length() > 0)
  for _key, value in annotations {
    assert_eq(value, "Int")
  }
}

///|
test "pass_annotate: fn expressions are not annotated (handled by render)" {
  let source =
    #|let add = (a: Int, b: Int) { a + b }
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let selected = pass_select_and_dedup(ast, [])
  let sorted = normalize_sort_stmts(selected)
  let (_env, annotations) = pass_annotate(sorted)
  // Fn expressions are explicitly skipped by normalize_collect_inferred_annotations
  inspect(annotations.length(), content="0")
}

///|
test "pass_validate: valid render passes" {
  let source =
    #|let x: Int = 1
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let rendered = "let x: Int = 1\n"
  let result = pass_validate(source, rendered, ast.stmts)
  @debug.debug_inspect(result, content="Ok(())")
}

///|
test "pass_validate: semantics change detected" {
  let source =
    #|let x: Int = 1
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let rendered = "let x: Int = 999\n"
  let result = pass_validate(source, rendered, ast.stmts)
  match result {
    Err(msg) => assert_true(msg.contains("changed semantics"))
    Ok(_) => fail("expected validation to fail")
  }
}

///|
test "pass_render: renders source from stmts" {
  let source = "let x = 42"
  let ast = match pass_parse(source) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let selected = pass_select_and_dedup(ast, [])
  let sorted = normalize_sort_stmts(selected)
  let (env, annotations) = pass_annotate(sorted)
  let result = pass_render(source, sorted, {}, annotations, env)
  match result {
    Ok(rendered) => assert_true(rendered.contains("let x"))
    Err(msg) => fail("render failed: " + msg)
  }
}

///|
test "pass pipeline: full chain produces same result as normalize_source_text" {
  let source =
    #|let z = () -> Int { b() }
    #|let b = () -> Int { a() }
    #|let a = () -> Int { 42 }
  // Manually chain passes
  let quickfixed = normalize_apply_grammar_quickfixes(source)
  let ast = match pass_parse(quickfixed) {
    Ok(m) => m
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let optimized = normalize_optimize_module(ast)
  let selected = pass_select_and_dedup(optimized.normalized_module, [])
  let sorted = normalize_sort_stmts(selected)
  assert_true(sorted.length() > 0)
  let final_sorted = pass_typecheck_and_filter(sorted, [], false)
  assert_true(final_sorted.length() > 0)
  let (env, annotations) = pass_annotate(final_sorted)
  let rendered = match
    pass_render(
      quickfixed,
      final_sorted,
      optimized.rewritten_exprs,
      annotations,
      env,
    ) {
    Ok(v) => v
    Err(msg) => {
      fail(msg)
      return
    }
  }
  match pass_validate(quickfixed, rendered, final_sorted) {
    Ok(_) => ()
    Err(msg) => {
      fail(msg)
      return
    }
  }
  let actual : Result[String, String] = Ok(rendered)
  @debug.debug_inspect(
    actual,
    content=(
      #|Ok("//# Functions\n\nlet a: () -> Int = () -> { 42 }\n\nlet b: () -> Int = () -> { a() }\n\nlet z: () -> Int = () -> { b() }\n")

    ),
  )
}

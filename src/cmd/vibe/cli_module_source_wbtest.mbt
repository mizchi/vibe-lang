///|
test "build_module_source_from_source keeps reachable defs for entry" {
  let source = "let value = 1\n" +
    "let helper = () -> Int { 1 }\n" +
    "export let main = () -> Int { helper() }\n" +
    "let text = \"ignored\"\n"
  let module_source = match build_module_source_from_source(source, "main") {
    Ok(v) => v
    Err(err) => fail(err)
  }
  inspect(
    module_source,
    content="let helper = () -> Int { 1 }\n" +
      "export let main = () -> Int { helper() }\n" +
      "let text = \"ignored\"\n",
  )
}

///|
test "build_module_source_from_source keeps required type defs" {
  let source = "export enum Shape { Circle(Int) }\n" +
    "let ignored = 1\n" +
    "let helper = (shape: Shape) -> Int { match shape { Circle(r) => r } }\n" +
    "export let main = () -> Int { helper(Circle(3)) }\n"
  let module_source = match build_module_source_from_source(source, "main") {
    Ok(v) => v
    Err(err) => fail(err)
  }
  inspect(
    module_source,
    content="export enum Shape { Circle(Int) }\n" +
      "let helper = (shape: Shape) -> Int { match shape { Circle(r) => r } }\n" +
      "export let main = () -> Int { helper(Circle(3)) }\n",
  )
}

///|
test "build_module_source_from_source keeps parse errors" {
  let result = build_module_source_from_source("let =", "main")
  if not(result is Err(_)) {
    fail("expected parse error")
  }
}

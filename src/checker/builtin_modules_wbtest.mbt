///|
test "builtin module sources parse with current syntax" {
  for pair in builtin_module_sources {
    let (name, source) = pair
    if name == "builtin/int" ||
      name == "builtin/float" ||
      name == "builtin/double" {
      let parsed : Result[@core.Module, @parser.ParseError] = try? @parser.parse_ast(
        source,
      )
      match parsed {
        Ok(_) => ()
        Err(err) =>
          fail(
            "builtin module source failed to parse: " +
            name +
            "\n" +
            err.to_string(),
          )
      }
    }
  }
}

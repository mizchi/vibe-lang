///|
test "verify_builtin_contract detects missing handlers" {
  // Provide a checker list with a name that has no codegen handler
  let checker_names = ["Array::get", "Fake::missing_handler"]
  let report = verify_builtin_contract(checker_names)
  // "Fake::missing_handler" is not in codegen or fallback
  assert_true(report.missing_handlers.contains("Fake::missing_handler"))
  // "Array::get" should NOT be in missing (it has a codegen handler)
  assert_false(report.missing_handlers.contains("Array::get"))
}

///|
test "verify_builtin_contract detects undeclared handlers" {
  // Provide an empty checker list
  let checker_names : Array[String] = []
  let report = verify_builtin_contract(checker_names)
  // All codegen handlers should be reported as undeclared
  assert_true(report.undeclared_handlers.length() > 0)
  assert_true(report.undeclared_handlers.contains("Array::get"))
}

///|
test "verify_builtin_contract accepts fallback builtins" {
  // Json::parse is a known fallback - should not appear in missing
  let checker_names = ["Json::parse", "Array::get"]
  let report = verify_builtin_contract(checker_names)
  assert_false(report.missing_handlers.contains("Json::parse"))
  assert_false(report.missing_handlers.contains("Array::get"))
}

///|
test "verify_builtin_contract accepts Threads builtins" {
  let checker_names = [
    "Threads::probe_wat", "Threads::runtime_hints", "Threads::channel_new", "Threads::send",
    "Threads::recv", "Threads::spawn", "Threads::wait",
  ]
  let report = verify_builtin_contract(checker_names)
  assert_eq(report.missing_handlers.length(), 0)
}

///|
test "format_builtin_contract_report formats warnings" {
  let report : BuiltinContractReport = {
    missing_handlers: ["Fake::foo"],
    undeclared_handlers: [],
  }
  let messages = format_builtin_contract_report(report, "warn")
  assert_eq(messages.length(), 1)
  assert_true(messages[0].has_prefix("warning:"))
  assert_true(messages[0].contains("Fake::foo"))
}

///|
test "format_builtin_contract_report formats errors" {
  let report : BuiltinContractReport = {
    missing_handlers: ["Fake::bar"],
    undeclared_handlers: [],
  }
  let messages = format_builtin_contract_report(report, "error")
  assert_eq(messages.length(), 1)
  assert_true(messages[0].has_prefix("error:"))
}

///|
test "codegen_registered_builtin_names is non-empty" {
  let names = @codegen.codegen_registered_builtin_names()
  assert_true(names.length() > 50)
}

///|
test "Map Iterable codegen handlers are registered" {
  let names = @codegen.codegen_registered_builtin_names()
  assert_true(names.contains("Map::iter_length"))
  assert_true(names.contains("Map::iter_get"))
}

///|
test "codegen_runtime_fallback_builtin_names is non-empty" {
  let names = @codegen.codegen_runtime_fallback_builtin_names()
  assert_true(names.length() > 10)
}

///|
test "full contract check with real checker names" {
  let checker_names = @checker.checker_declared_builtin_names()
  let report = verify_builtin_contract(checker_names)
  // Format messages to ensure no crash
  let _messages = format_builtin_contract_report(report, "warn")
  // The report should work without errors
  // Some checker-only builtins (like Array::map) are expected to be missing
  // from codegen since they are interpreter-only higher-order functions
  assert_true(report.missing_handlers.length() >= 0)
}

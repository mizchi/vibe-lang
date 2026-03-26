///|
/// Result of a builtin contract verification check.
pub struct BuiltinContractReport {
  /// Builtins declared in checker but missing from both codegen and fallback.
  missing_handlers : Array[String]
  /// Builtins with codegen handlers but not declared in checker.
  undeclared_handlers : Array[String]
} derive(Show, Eq)

///|
/// Verify that checker-declared builtins are covered by codegen handlers
/// or runtime fallback entries.
/// Returns a report of mismatches.
pub fn verify_builtin_contract(
  checker_declared : Array[String],
) -> BuiltinContractReport {
  let codegen_names = @codegen.codegen_registered_builtin_names()
  let fallback_names = @codegen.codegen_runtime_fallback_builtin_names()
  // Build a set of all names that have codegen coverage
  let covered : Map[String, Bool] = {}
  for name in codegen_names {
    covered[name] = true
  }
  for name in fallback_names {
    covered[name] = true
  }
  // Build a set of checker-declared names
  let declared : Map[String, Bool] = {}
  for name in checker_declared {
    declared[name] = true
  }
  // Find declared but not covered
  let missing_handlers : Array[String] = []
  for name in checker_declared {
    if not(covered.contains(name)) {
      missing_handlers.push(name)
    }
  }
  // Find covered but not declared (codegen only, not fallback)
  let undeclared_handlers : Array[String] = []
  for name in codegen_names {
    if not(declared.contains(name)) {
      undeclared_handlers.push(name)
    }
  }
  { missing_handlers, undeclared_handlers }
}

///|
/// Format a contract report as human-readable messages.
/// Returns an array of warning/error strings.
pub fn format_builtin_contract_report(
  report : BuiltinContractReport,
  level : String,
) -> Array[String] {
  let messages : Array[String] = []
  let prefix = if level == "error" { "error" } else { "warning" }
  for name in report.missing_handlers {
    messages.push(
      prefix +
      ": builtin '" +
      name +
      "' declared in checker but no codegen handler registered",
    )
  }
  for name in report.undeclared_handlers {
    messages.push(
      "warning: builtin '" +
      name +
      "' has codegen handler but not declared in checker",
    )
  }
  messages
}

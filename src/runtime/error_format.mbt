///|
/// Format an ErrorCode into a human-readable error message string.
/// This is the single point where display strings are constructed.
pub fn format_error(code : ErrorCode) -> String {
  match code {
    OpType(op~, left~, right~) =>
      op + ": type mismatch, got " + left + " " + op + " " + right
    OpArity(op~, expected~, got~) =>
      op +
      ": expected " +
      expected.to_string() +
      " argument" +
      (if expected != 1 { "s" } else { "" }) +
      ", got " +
      got.to_string()
    DivByZero(op~) => op + ": division by zero"
    CmpType(left~, right~) =>
      "comparison: type mismatch, cannot compare " + left + " with " + right
    UnaryType(op~, got~) => "unary " + op + ": expected number, got " + got
    IndexOOB(op~, index~, length~) =>
      op +
      ": index " +
      index.to_string() +
      " out of bounds (length " +
      length.to_string() +
      ")"
    IndexType(container~, key~) =>
      "[]: cannot index " + container + " with " + key
    MissingKey(op~, key~) => op + ": missing key '" + key + "'"
    SetIndexOOB(index~, length~) =>
      "[]=: index " +
      index.to_string() +
      " out of bounds (length " +
      length.to_string() +
      ")"
    SetIndexType(target~) => "[]=: cannot assign index on " + target
    NoField(field~, on~) =>
      "no field '" +
      field +
      "' on " +
      on +
      (if on != "Record" { " (field access requires a Record)" } else { "" })
    NotFn(name~, got~) =>
      "'" + name + "' is not a function (has type " + got + ")"
    TooManyArgs(expected~) =>
      "too many positional arguments: expected " +
      expected.to_string() +
      ", got more"
    MissingArgs(expected~, got~) =>
      "missing positional arguments: expected " +
      expected.to_string() +
      ", got " +
      got.to_string()
    UnknownFn(name~) => "unknown function '" + name + "'"
    DupLabel(label~) => "duplicate label: " + label
    UnknownLabel(label~) => "unknown label: " + label
    MissingLabel(label~) => "missing label: " + label
    DupVariadic => "duplicate variadic params"
    PosAfterVariadic => "positional param after variadic is unsupported"
    CondNotBool(ctx~, got~) => ctx + " condition must be Bool, got " + got
    AssertFail => "assertion failed"
    AssertType(got~) => "assert: expected Bool, got " + got
    TupleOOB(index~) => "tuple index " + index.to_string() + " out of bounds"
    TupleType => "expected tuple for index access"
    AssignImm(name~) => "assign to immutable: " + name
    LetPatFail => "let-pat: pattern match failed"
    MainNotFn => "main is not a function"
    MainNotDefined => "main is not defined"
    BuiltinArity(fn_name~, expected~, got~) =>
      fn_name +
      ": expected " +
      expected.to_string() +
      " argument" +
      (if expected != 1 { "s" } else { "" }) +
      ", got " +
      got.to_string()
    BuiltinType(fn_name~, expected~, got~) =>
      fn_name + ": expected " + expected + ", got " + got
    BuiltinDetail(fn_name~, detail~) => fn_name + ": " + detail
    JsonParse(detail~) => "from_json: " + detail
    Io(op~, detail~) => if detail == "" { op } else { op + ": " + detail }
    Llm(op~, detail~) => op + ": " + detail
    Effect(detail~) => detail
    E(msg) => msg
  }
}

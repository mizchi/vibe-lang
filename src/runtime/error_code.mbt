///|
/// Structured runtime error codes.
/// Format is handled by format_error() in error_format.mbt.
pub(all) enum ErrorCode {
  // --- Operators ---
  OpType(op~ : String, left~ : String, right~ : String)
  OpArity(op~ : String, expected~ : Int, got~ : Int)
  DivByZero(op~ : String)
  CmpType(left~ : String, right~ : String)
  UnaryType(op~ : String, got~ : String)

  // --- Index / Access ---
  IndexOOB(op~ : String, index~ : Int, length~ : Int)
  IndexType(container~ : String, key~ : String)
  MissingKey(op~ : String, key~ : String)
  SetIndexOOB(index~ : Int, length~ : Int)
  SetIndexType(target~ : String)
  NoField(field~ : String, on~ : String)

  // --- Function call ---
  NotFn(name~ : String, got~ : String)
  TooManyArgs(expected~ : Int)
  MissingArgs(expected~ : Int, got~ : Int)
  UnknownFn(name~ : String)

  // --- Labels ---
  DupLabel(label~ : String)
  UnknownLabel(label~ : String)
  MissingLabel(label~ : String)
  DupVariadic
  PosAfterVariadic

  // --- Control flow ---
  CondNotBool(ctx~ : String, got~ : String)
  AssertFail
  AssertType(got~ : String)
  TupleOOB(index~ : Int)
  TupleType
  AssignImm(name~ : String)
  LetPatFail
  MainNotFn
  MainNotDefined

  // --- Builtin (generic, covers ~200 sites) ---
  BuiltinArity(fn_name~ : String, expected~ : Int, got~ : Int)
  BuiltinType(fn_name~ : String, expected~ : String, got~ : String)
  BuiltinDetail(fn_name~ : String, detail~ : String)

  // --- Domain-specific ---
  JsonParse(detail~ : String)
  Io(op~ : String, detail~ : String)
  Llm(op~ : String, detail~ : String)
  Effect(detail~ : String)

  // --- Fallback ---
  E(String)
} derive(Eq)

///|
pub impl Show for ErrorCode with output(self, logger) {
  logger.write_string(format_error(self))
}

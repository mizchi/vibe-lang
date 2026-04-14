///|
/// vibe public API
suberror VibeError {
  Parse(@core.Diagnostic)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Eq)

///|
pub impl Show for VibeError with output(self, logger) {
  match self {
    VibeError::Parse(diagnostic) => diagnostic.output(logger)
    VibeError::Type(error) => error.output(logger)
    VibeError::Eval(error) => error.output(logger)
  }
}

///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
} derive(Debug, Eq)

///|
pub impl Show for ParserMode with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

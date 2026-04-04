///|
/// vibe public API
suberror VibeError {
  Parse(@core.Diagnostic)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
} derive(Show, Eq)

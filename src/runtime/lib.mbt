///|
/// vibe public API
suberror VibeError {
  Parse(@parser.ParseError)
  Type(@checker.TypeError)
  Eval(EvalError)
} derive(Show, Eq)

///|
pub(all) enum ParserMode {
  VibeMode
  PosixMode
  PosixStrictMode
} derive(Show, Eq)
